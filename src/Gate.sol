// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.4;

import {ERC20} from "solmate/tokens/ERC20.sol";
import {SafeTransferLib} from "solmate/utils/SafeTransferLib.sol";
import {Bytes32AddressLib} from "solmate/utils/Bytes32AddressLib.sol";

import {Ownable} from "./lib/Ownable.sol";
import {FullMath} from "./lib/FullMath.sol";
import {NegativeYieldToken} from "./NegativeYieldToken.sol";
import {PerpetualYieldToken} from "./PerpetualYieldToken.sol";

/// @title Gate
/// @author zefram.eth
/// @notice Gate is the main contract users interact with to mint/burn NegativeYieldToken
/// and PerpetualYieldToken, as well as claim the yield earned by PYTs.
/// @dev Gate is an abstract contract that should be inherited from in order to support
/// a specific vault protocol (e.g. YearnGate supports YearnVault). Each Gate handles
/// all vaults & associated NYTs/PYTs of a specific vault protocol.
///
/// Vaults are yield-generating contracts used by Gate. Gate makes several assumptions about
/// a vault:
/// 1) A vault has a single associated underlying token that is immutable.
/// 2) A vault gives depositors yield denominated in the underlying token.
/// 3) A vault depositor owns shares in the vault, which represents their deposit.
/// 4) Vaults have a notion of "price per share", which is the amount of underlying tokens
///    each vault share can be redeemed for.
/// 5) If vault shares are represented using an ERC20 token, then the ERC20 token contract must be
///    the vault contract itself.
abstract contract Gate is Ownable {
    /// -----------------------------------------------------------------------
    /// Library usage
    /// -----------------------------------------------------------------------

    using SafeTransferLib for ERC20;
    using Bytes32AddressLib for address;
    using Bytes32AddressLib for bytes32;

    /// -----------------------------------------------------------------------
    /// Errors
    /// -----------------------------------------------------------------------

    error Error_ProtocolFeeRecipientIsZero();
    error Error_VaultSharesNotERC20();
    error Error_TokenPairNotDeployed();
    error Error_SenderNotPerpetualYieldToken();

    /// -----------------------------------------------------------------------
    /// Events
    /// -----------------------------------------------------------------------

    event EnterWithUnderlying(
        address indexed sender,
        address indexed recipient,
        address indexed vault,
        uint256 underlyingAmount
    );
    event EnterWithVaultShares(
        address indexed sender,
        address indexed recipient,
        address indexed vault,
        uint256 vaultSharesAmount
    );
    event ExitToUnderlying(
        address indexed sender,
        address indexed recipient,
        address indexed vault,
        uint256 underlyingAmount
    );
    event ExitToVaultShares(
        address indexed sender,
        address indexed recipient,
        address indexed vault,
        uint256 vaultSharesAmount
    );
    event ClaimYieldInUnderlying(
        address indexed sender,
        address indexed recipient,
        address indexed vault,
        uint256 underlyingAmount
    );
    event ClaimYieldInVaultShares(
        address indexed sender,
        address indexed recipient,
        address indexed vault,
        uint256 vaultSharesAmount
    );
    event DeployTokenPairForVault(
        address indexed vault,
        NegativeYieldToken nyt,
        PerpetualYieldToken pyt
    );
    event SetProtocolFee(ProtocolFeeInfo protocolFeeInfo_);

    /// -----------------------------------------------------------------------
    /// Constants
    /// -----------------------------------------------------------------------

    /// @notice The precision used by yieldPerTokenStored
    uint256 internal constant PRECISION = 10**27;

    /// -----------------------------------------------------------------------
    /// Storage variables
    /// -----------------------------------------------------------------------

    struct ProtocolFeeInfo {
        uint8 fee; // each increment represents 0.1%, so max is 25.5%
        address recipient;
    }
    /// @notice The protocol fee and the fee recipient address.
    ProtocolFeeInfo public protocolFeeInfo;

    /// @notice The amount of underlying tokens each vault share is worth, at the time of the last update.
    /// @dev vault => value
    mapping(address => uint256) public pricePerVaultShareStored;

    /// @notice The amount of yield each PYT has accrued, at the time of the last update.
    /// Scaled by PRECISION.
    /// @dev vault => value
    mapping(address => uint256) public yieldPerTokenStored;

    /// @notice The amount of yield each PYT has accrued, at the time when a user has last interacted
    /// with the gate/PYT. Shifted by 1, so e.g. 3 represents 2, 10 represents 9.
    /// @dev vault => user => value
    /// The value is shifted to use 0 for representing uninitialized users.
    mapping(address => mapping(address => uint256))
        public userYieldPerTokenStored;

    /// @notice The amount of yield a user has accrued, at the time when they last interacted
    /// with the gate/PYT (without calling claimYieldInUnderlying()).
    /// @dev vault => user => value
    mapping(address => mapping(address => uint256)) public userAccruedYield;

    /// -----------------------------------------------------------------------
    /// Initialization
    /// -----------------------------------------------------------------------

    constructor(address initialOwner, ProtocolFeeInfo memory protocolFeeInfo_) {
        _transferOwnership(initialOwner);

        if (
            protocolFeeInfo_.fee != 0 &&
            protocolFeeInfo_.recipient == address(0)
        ) {
            revert Error_ProtocolFeeRecipientIsZero();
        }
        protocolFeeInfo = protocolFeeInfo_;
        emit SetProtocolFee(protocolFeeInfo_);
    }

    /// -----------------------------------------------------------------------
    /// User actions
    /// -----------------------------------------------------------------------

    /// @notice Converts underlying tokens into NegativeYieldToken and PerpetualYieldToken.
    /// The amount of NYT and PYT minted will be equal to the underlying token amount.
    /// @dev The underlying tokens will be immediately deposited into the specified vault.
    /// If the NYT and PYT for the specified vault haven't been deployed yet, this call will
    /// deploy them before proceeding, which will increase the gas cost significantly.
    /// @param recipient The recipient of the minted NYT and PYT
    /// @param vault The vault to mint NYT and PYT for
    /// @param underlyingAmount The amount of underlying tokens to use
    /// @return mintAmount The amount of NYT and PYT minted (the amounts are equal)
    function enterWithUnderlying(
        address recipient,
        address vault,
        uint256 underlyingAmount
    ) external virtual returns (uint256 mintAmount) {
        /// -----------------------------------------------------------------------
        /// Validation
        /// -----------------------------------------------------------------------

        if (underlyingAmount == 0) {
            return 0;
        }

        NegativeYieldToken nyt = getNegativeYieldTokenForVault(vault);
        if (address(nyt).code.length == 0) {
            // token pair hasn't been deployed yet
            // do the deployment now
            // only need to check nyt since nyt and pyt are always deployed in pairs
            deployTokenPairForVault(vault);
        }
        PerpetualYieldToken pyt = getPerpetualYieldTokenForVault(vault);
        uint8 underlyingDecimals = nyt.decimals();

        /// -----------------------------------------------------------------------
        /// State updates
        /// -----------------------------------------------------------------------

        // accrue yield
        _accrueYield(vault, pyt, recipient, underlyingDecimals);

        // mint NYTs and PYTs
        mintAmount = underlyingAmount;
        nyt.gateMint(recipient, mintAmount);
        pyt.gateMint(recipient, mintAmount);

        /// -----------------------------------------------------------------------
        /// Effects
        /// -----------------------------------------------------------------------

        // transfer underlying from msg.sender to address(this)
        ERC20 underlying = getUnderlyingOfVault(vault);
        underlying.safeTransferFrom(
            msg.sender,
            address(this),
            underlyingAmount
        );

        // deposit underlying into vault
        _depositIntoVault(underlying, underlyingAmount, vault);

        emit EnterWithUnderlying(
            msg.sender,
            recipient,
            vault,
            underlyingAmount
        );
    }

    /// @notice Converts vault share tokens into NegativeYieldToken and PerpetualYieldToken.
    /// @dev Only available if vault shares are transferrable ERC20 tokens.
    /// If the NYT and PYT for the specified vault haven't been deployed yet, this call will
    /// deploy them before proceeding, which will increase the gas cost significantly.
    /// @param recipient The recipient of the minted NYT and PYT
    /// @param vault The vault to mint NYT and PYT for
    /// @param vaultSharesAmount The amount of vault share tokens to use
    /// @return mintAmount The amount of NYT and PYT minted (the amounts are equal)
    function enterWithVaultShares(
        address recipient,
        address vault,
        uint256 vaultSharesAmount
    ) external virtual returns (uint256 mintAmount) {
        /// -----------------------------------------------------------------------
        /// Validation
        /// -----------------------------------------------------------------------

        if (vaultSharesAmount == 0) {
            return 0;
        }

        // only supported if vault shares are ERC20
        if (!vaultSharesIsERC20()) {
            revert Error_VaultSharesNotERC20();
        }

        NegativeYieldToken nyt = getNegativeYieldTokenForVault(vault);
        if (address(nyt).code.length == 0) {
            // token pair hasn't been deployed yet
            // do the deployment now
            // only need to check nyt since nyt and pyt are always deployed in pairs
            deployTokenPairForVault(vault);
        }
        PerpetualYieldToken pyt = getPerpetualYieldTokenForVault(vault);
        uint8 underlyingDecimals = nyt.decimals();

        /// -----------------------------------------------------------------------
        /// State updates
        /// -----------------------------------------------------------------------

        // accrue yield
        _accrueYield(vault, pyt, recipient, underlyingDecimals);

        // mint NYTs and PYTs
        mintAmount = _vaultSharesAmountToUnderlyingAmount(
            vault,
            vaultSharesAmount,
            underlyingDecimals
        );
        nyt.gateMint(recipient, mintAmount);
        pyt.gateMint(recipient, mintAmount);

        /// -----------------------------------------------------------------------
        /// Effects
        /// -----------------------------------------------------------------------

        // transfer vault tokens from msg.sender to address(this)
        ERC20(vault).safeTransferFrom(
            msg.sender,
            address(this),
            vaultSharesAmount
        );

        emit EnterWithVaultShares(
            msg.sender,
            recipient,
            vault,
            vaultSharesAmount
        );
    }

    /// @notice Converts NegativeYieldToken and PerpetualYieldToken to underlying tokens.
    /// The amount of NYT and PYT burned will be equal to the underlying token amount.
    /// @dev The underlying tokens will be immediately withdrawn from the specified vault.
    /// If the NYT and PYT for the specified vault haven't been deployed yet, this call will
    /// revert.
    /// @param recipient The recipient of the minted NYT and PYT
    /// @param vault The vault to mint NYT and PYT for
    /// @param underlyingAmount The amount of underlying tokens requested
    /// @return burnAmount The amount of NYT and PYT burned (the amounts are equal)
    function exitToUnderlying(
        address recipient,
        address vault,
        uint256 underlyingAmount
    ) external virtual returns (uint256 burnAmount) {
        /// -----------------------------------------------------------------------
        /// Validation
        /// -----------------------------------------------------------------------

        if (underlyingAmount == 0) {
            return 0;
        }

        NegativeYieldToken nyt = getNegativeYieldTokenForVault(vault);
        PerpetualYieldToken pyt = getPerpetualYieldTokenForVault(vault);
        if (address(nyt).code.length == 0) {
            revert Error_TokenPairNotDeployed();
        }

        /// -----------------------------------------------------------------------
        /// State updates
        /// -----------------------------------------------------------------------

        uint8 underlyingDecimals = nyt.decimals();

        // accrue yield
        _accrueYield(vault, pyt, msg.sender, underlyingDecimals);

        // burn NYTs and PYTs
        burnAmount = underlyingAmount;
        nyt.gateBurn(msg.sender, burnAmount);
        pyt.gateBurn(msg.sender, burnAmount);

        /// -----------------------------------------------------------------------
        /// Effects
        /// -----------------------------------------------------------------------

        // withdraw underlying from vault to recipient
        // don't check balance since user can just withdraw slightly less
        // saves gas this way
        _withdrawFromVault(
            recipient,
            vault,
            underlyingAmount,
            underlyingDecimals,
            false
        );

        emit ExitToUnderlying(msg.sender, recipient, vault, underlyingAmount);
    }

    /// @notice Converts NegativeYieldToken and PerpetualYieldToken to vault share tokens.
    /// The amount of NYT and PYT burned will be equal to the underlying token amount.
    /// @dev Only available if vault shares are transferrable ERC20 tokens.
    /// If the NYT and PYT for the specified vault haven't been deployed yet, this call will
    /// revert.
    /// @param recipient The recipient of the minted NYT and PYT
    /// @param vault The vault to mint NYT and PYT for
    /// @param vaultSharesAmount The amount of vault share tokens requested
    /// @return burnAmount The amount of NYT and PYT burned (the amounts are equal)
    function exitToVaultShares(
        address recipient,
        address vault,
        uint256 vaultSharesAmount
    ) external virtual returns (uint256 burnAmount) {
        /// -----------------------------------------------------------------------
        /// Validation
        /// -----------------------------------------------------------------------

        if (vaultSharesAmount == 0) {
            return 0;
        }

        // only supported if vault shares are ERC20
        if (!vaultSharesIsERC20()) {
            revert Error_VaultSharesNotERC20();
        }

        NegativeYieldToken nyt = getNegativeYieldTokenForVault(vault);
        PerpetualYieldToken pyt = getPerpetualYieldTokenForVault(vault);
        if (address(nyt).code.length == 0) {
            revert Error_TokenPairNotDeployed();
        }

        /// -----------------------------------------------------------------------
        /// State updates
        /// -----------------------------------------------------------------------

        uint8 underlyingDecimals = nyt.decimals();

        // accrue yield
        _accrueYield(vault, pyt, msg.sender, underlyingDecimals);

        // burn NYTs and PYTs
        burnAmount = _vaultSharesAmountToUnderlyingAmount(
            vault,
            vaultSharesAmount,
            underlyingDecimals
        );
        nyt.gateBurn(msg.sender, burnAmount);
        pyt.gateBurn(msg.sender, burnAmount);

        /// -----------------------------------------------------------------------
        /// Effects
        /// -----------------------------------------------------------------------

        // transfer vault tokens to recipient
        ERC20(vault).safeTransfer(recipient, vaultSharesAmount);

        emit ExitToVaultShares(msg.sender, recipient, vault, vaultSharesAmount);
    }

    /// @notice Deploys the NegativeYieldToken and PerpetualYieldToken associated with a vault.
    /// @dev Will revert if they have already been deployed.
    /// @param vault The vault to deploy NYT and PYT for
    /// @return nyt The deployed NegativeYieldToken
    /// @return pyt The deployed PerpetualYieldToken
    function deployTokenPairForVault(address vault)
        public
        virtual
        returns (NegativeYieldToken nyt, PerpetualYieldToken pyt)
    {
        // Use the CREATE2 opcode to deploy new NegativeYieldToken and PerpetualYieldToken contracts.
        // This will revert if the contracts have already been deployed,
        // as the salt would be the same and we can't deploy with it twice.
        nyt = new NegativeYieldToken{salt: vault.fillLast12Bytes()}(
            address(this),
            vault
        );
        pyt = new PerpetualYieldToken{salt: vault.fillLast12Bytes()}(
            address(this),
            vault
        );

        emit DeployTokenPairForVault(vault, nyt, pyt);
    }

    /// @notice Claims the yield earned by the PerpetualYieldToken balance of msg.sender, in the underlying token.
    /// @dev If the NYT and PYT for the specified vault haven't been deployed yet, this call will
    /// revert.
    /// @param recipient The recipient of the yield
    /// @param vault The vault to claim yield from
    /// @return yieldAmount The amount of yield claimed, in underlying tokens
    function claimYieldInUnderlying(address recipient, address vault)
        external
        virtual
        returns (uint256 yieldAmount)
    {
        /// -----------------------------------------------------------------------
        /// Validation
        /// -----------------------------------------------------------------------

        PerpetualYieldToken pyt = getPerpetualYieldTokenForVault(vault);
        if (address(pyt).code.length == 0) {
            revert Error_TokenPairNotDeployed();
        }

        /// -----------------------------------------------------------------------
        /// State updates
        /// -----------------------------------------------------------------------

        uint8 underlyingDecimals = pyt.decimals();

        // accrue yield
        uint256 updatedPricePerVaultShare = getPricePerVaultShare(vault);
        uint256 updatedYieldPerToken = _computeYieldPerToken(
            vault,
            pyt,
            updatedPricePerVaultShare,
            underlyingDecimals
        );
        uint256 userYieldPerTokenStored_ = userYieldPerTokenStored[vault][
            msg.sender
        ];
        if (userYieldPerTokenStored_ != 0) {
            yieldAmount = _getClaimableYieldAmount(
                vault,
                pyt,
                msg.sender,
                updatedYieldPerToken,
                userYieldPerTokenStored_
            );
        }
        yieldPerTokenStored[vault] = updatedYieldPerToken;
        pricePerVaultShareStored[vault] = updatedPricePerVaultShare;
        userYieldPerTokenStored[vault][msg.sender] = updatedYieldPerToken + 1;

        // withdraw yield
        if (yieldAmount != 0) {
            userAccruedYield[vault][msg.sender] = 0;

            /// -----------------------------------------------------------------------
            /// Effects
            /// -----------------------------------------------------------------------

            ProtocolFeeInfo memory protocolFeeInfo_ = protocolFeeInfo;
            uint256 fee = protocolFeeInfo_.fee;

            if (fee != 0) {
                uint256 protocolFee = (yieldAmount * fee) / 1000;
                unchecked {
                    // can't underflow since fee < 256
                    yieldAmount -= protocolFee;
                }

                if (vaultSharesIsERC20()) {
                    // vault shares are in ERC20
                    // do share transfer
                    protocolFee = _underlyingAmountToVaultSharesAmount(
                        vault,
                        protocolFee,
                        underlyingDecimals
                    );
                    ERC20(vault).safeTransfer(
                        protocolFeeInfo_.recipient,
                        protocolFee
                    );
                } else {
                    // vault shares are not in ERC20
                    // withdraw underlying from vault
                    // checkBalance is set to false since we know there will
                    // still be nonnegligible vault shares after this
                    _withdrawFromVault(
                        protocolFeeInfo_.recipient,
                        vault,
                        protocolFee,
                        underlyingDecimals,
                        false
                    );
                }
            }

            // withdraw underlying to recipient
            // checkBalance is set to true to prevent getting stuck
            // due to rounding errors
            _withdrawFromVault(
                recipient,
                vault,
                yieldAmount,
                underlyingDecimals,
                true
            );

            emit ClaimYieldInUnderlying(
                msg.sender,
                recipient,
                vault,
                yieldAmount
            );
        }
    }

    /// @notice Claims the yield earned by the PerpetualYieldToken balance of msg.sender, in vault shares.
    /// @dev Only available if vault shares are transferrable ERC20 tokens.
    /// If the NYT and PYT for the specified vault haven't been deployed yet, this call will
    /// revert.
    /// @param recipient The recipient of the yield
    /// @param vault The vault to claim yield from
    /// @return yieldAmount The amount of yield claimed, in vault shares
    function claimYieldInVaultShares(address recipient, address vault)
        external
        virtual
        returns (uint256 yieldAmount)
    {
        /// -----------------------------------------------------------------------
        /// Validation
        /// -----------------------------------------------------------------------

        // only supported if vault shares are ERC20
        if (!vaultSharesIsERC20()) {
            revert Error_VaultSharesNotERC20();
        }

        PerpetualYieldToken pyt = getPerpetualYieldTokenForVault(vault);
        if (address(pyt).code.length == 0) {
            revert Error_TokenPairNotDeployed();
        }

        /// -----------------------------------------------------------------------
        /// State updates
        /// -----------------------------------------------------------------------

        uint8 underlyingDecimals = pyt.decimals();

        // accrue yield
        uint256 updatedPricePerVaultShare = getPricePerVaultShare(vault);
        uint256 updatedYieldPerToken = _computeYieldPerToken(
            vault,
            pyt,
            updatedPricePerVaultShare,
            underlyingDecimals
        );
        uint256 userYieldPerTokenStored_ = userYieldPerTokenStored[vault][
            msg.sender
        ];
        if (userYieldPerTokenStored_ != 0) {
            yieldAmount = _getClaimableYieldAmount(
                vault,
                pyt,
                msg.sender,
                updatedYieldPerToken,
                userYieldPerTokenStored_
            );
        }
        yieldPerTokenStored[vault] = updatedYieldPerToken;
        pricePerVaultShareStored[vault] = updatedPricePerVaultShare;
        userYieldPerTokenStored[vault][msg.sender] = updatedYieldPerToken + 1;

        // withdraw yield
        if (yieldAmount != 0) {
            userAccruedYield[vault][msg.sender] = 0;

            /// -----------------------------------------------------------------------
            /// Effects
            /// -----------------------------------------------------------------------

            // convert yieldAmount to be denominated in vault shares
            yieldAmount = _underlyingAmountToVaultSharesAmount(
                vault,
                yieldAmount,
                underlyingDecimals
            );

            ProtocolFeeInfo memory protocolFeeInfo_ = protocolFeeInfo;
            uint256 fee = protocolFeeInfo_.fee;

            if (fee != 0) {
                uint256 protocolFee = (yieldAmount * fee) / 1000;
                unchecked {
                    // can't underflow since fee < 256
                    yieldAmount -= protocolFee;
                }

                ERC20(vault).safeTransfer(
                    protocolFeeInfo_.recipient,
                    protocolFee
                );
            }

            // transfer vault shares to recipient
            // check if vault shares is enough to prevent getting stuck
            // from rounding errors
            uint256 vaultSharesBalance = getVaultShareBalance(vault);
            yieldAmount = yieldAmount > vaultSharesBalance
                ? vaultSharesBalance
                : yieldAmount;
            ERC20(vault).safeTransfer(recipient, yieldAmount);

            emit ClaimYieldInVaultShares(
                msg.sender,
                recipient,
                vault,
                yieldAmount
            );
        }
    }

    /// -----------------------------------------------------------------------
    /// Getters
    /// -----------------------------------------------------------------------

    /// @notice Returns the NegativeYieldToken associated with a vault.
    /// @dev Returns non-zero value even if the contract hasn't been deployed yet.
    /// @param vault The vault to query
    /// @return The NegativeYieldToken address
    function getNegativeYieldTokenForVault(address vault)
        public
        view
        virtual
        returns (NegativeYieldToken)
    {
        return
            NegativeYieldToken(
                keccak256(
                    abi.encodePacked(
                        // Prefix:
                        bytes1(0xFF),
                        // Creator:
                        address(this),
                        // Salt:
                        address(vault).fillLast12Bytes(),
                        // Bytecode hash:
                        keccak256(
                            abi.encodePacked(
                                // Deployment bytecode:
                                type(NegativeYieldToken).creationCode,
                                // Constructor arguments:
                                abi.encode(address(this), vault)
                            )
                        )
                    )
                ).fromLast20Bytes() // Convert the CREATE2 hash into an address.
            );
    }

    /// @notice Returns the PerpetualYieldToken associated with a vault.
    /// @dev Returns non-zero value even if the contract hasn't been deployed yet.
    /// @param vault The vault to query
    /// @return The PerpetualYieldToken address
    function getPerpetualYieldTokenForVault(address vault)
        public
        view
        virtual
        returns (PerpetualYieldToken)
    {
        return
            PerpetualYieldToken(
                keccak256(
                    abi.encodePacked(
                        // Prefix:
                        bytes1(0xFF),
                        // Creator:
                        address(this),
                        // Salt:
                        address(vault).fillLast12Bytes(),
                        // Bytecode hash:
                        keccak256(
                            abi.encodePacked(
                                // Deployment bytecode:
                                type(PerpetualYieldToken).creationCode,
                                // Constructor arguments:
                                abi.encode(address(this), vault)
                            )
                        )
                    )
                ).fromLast20Bytes() // Convert the CREATE2 hash into an address.
            );
    }

    /// @notice Returns the amount of yield claimable by a PerpetualYieldToken holder from a vault.
    /// @param vault The vault to query
    /// @param user The PYT holder to query
    /// @return The amount of yield claimable
    function getClaimableYieldAmount(address vault, address user)
        external
        view
        virtual
        returns (uint256)
    {
        PerpetualYieldToken pyt = getPerpetualYieldTokenForVault(vault);
        uint256 userYieldPerTokenStored_ = userYieldPerTokenStored[vault][user];
        if (userYieldPerTokenStored_ == 0) {
            // uninitialized account
            return 0;
        }
        return
            _getClaimableYieldAmount(
                vault,
                pyt,
                user,
                _computeYieldPerToken(
                    vault,
                    pyt,
                    getPricePerVaultShare(vault),
                    pyt.decimals()
                ),
                userYieldPerTokenStored_
            );
    }

    /// @notice Computes the latest yieldPerToken value for a vault.
    /// @param vault The vault to query
    /// @return The latest yieldPerToken value
    function computeYieldPerToken(address vault)
        external
        view
        virtual
        returns (uint256)
    {
        PerpetualYieldToken pyt = getPerpetualYieldTokenForVault(vault);
        return
            _computeYieldPerToken(
                vault,
                pyt,
                getPricePerVaultShare(vault),
                pyt.decimals()
            );
    }

    /// @notice Returns the underlying token of a vault.
    /// @param vault The vault to query
    /// @return The underlying token
    function getUnderlyingOfVault(address vault)
        public
        view
        virtual
        returns (ERC20);

    /// @notice Returns the amount of underlying tokens each share of a vault is worth.
    /// @param vault The vault to query
    /// @return The pricePerVaultShare value
    function getPricePerVaultShare(address vault)
        public
        view
        virtual
        returns (uint256);

    /// @notice Returns the amount of vault shares owned by the gate.
    /// @param vault The vault to query
    /// @return The gate's vault share balance
    function getVaultShareBalance(address vault)
        public
        view
        virtual
        returns (uint256);

    /// @return True if the vaults supported by this gate use transferrable ERC20 tokens
    /// to represent shares, false otherwise.
    function vaultSharesIsERC20() public pure virtual returns (bool);

    /// @notice Computes the ERC20 name of the NegativeYieldToken of a vault.
    /// @param vault The vault to query
    /// @return The ERC20 name
    function negativeYieldTokenName(address vault)
        external
        view
        virtual
        returns (string memory);

    /// @notice Computes the ERC20 symbol of the NegativeYieldToken of a vault.
    /// @param vault The vault to query
    /// @return The ERC20 symbol
    function negativeYieldTokenSymbol(address vault)
        external
        view
        virtual
        returns (string memory);

    /// @notice Computes the ERC20 name of the PerpetualYieldToken of a vault.
    /// @param vault The vault to query
    /// @return The ERC20 name
    function perpetualYieldTokenName(address vault)
        external
        view
        virtual
        returns (string memory);

    /// @notice Computes the ERC20 symbol of the NegativeYieldToken of a vault.
    /// @param vault The vault to query
    /// @return The ERC20 symbol
    function perpetualYieldTokenSymbol(address vault)
        external
        view
        virtual
        returns (string memory);

    /// -----------------------------------------------------------------------
    /// PYT transfer hook
    /// -----------------------------------------------------------------------

    /// @notice SHOULD NOT BE CALLED BY USERS, ONLY CALLED BY PERPETUAL YIELD TOKEN CONTRACTS
    /// @dev Called by PYT contracts deployed by this gate before each token transfer, in order to
    /// accrue the yield earned by the from & to accounts
    /// @param from The token transfer from account
    /// @param to The token transfer to account
    function beforePerpetualYieldTokenTransfer(
        address from,
        address to,
        uint256 amount
    ) external virtual {
        /// -----------------------------------------------------------------------
        /// Validation
        /// -----------------------------------------------------------------------

        if (amount == 0) {
            return;
        }

        address vault = PerpetualYieldToken(msg.sender).vault();
        PerpetualYieldToken pyt = getPerpetualYieldTokenForVault(vault);
        if (msg.sender != address(pyt)) {
            revert Error_SenderNotPerpetualYieldToken();
        }

        /// -----------------------------------------------------------------------
        /// State updates
        /// -----------------------------------------------------------------------

        // accrue yield
        uint256 updatedPricePerVaultShare = getPricePerVaultShare(vault);
        uint256 updatedYieldPerToken = _computeYieldPerToken(
            vault,
            pyt,
            updatedPricePerVaultShare,
            pyt.decimals()
        );
        yieldPerTokenStored[vault] = updatedYieldPerToken;
        pricePerVaultShareStored[vault] = updatedPricePerVaultShare;

        // we know the from account must have held PYTs before
        // so we will always accrue the yield earned by the from account
        userAccruedYield[vault][from] = _getClaimableYieldAmount(
            vault,
            pyt,
            from,
            updatedYieldPerToken,
            userYieldPerTokenStored[vault][from]
        );
        userYieldPerTokenStored[vault][from] = updatedYieldPerToken + 1;

        // the to account might not have held PYTs before
        // we only accrue yield if they have
        uint256 toUserYieldPerTokenStored = userYieldPerTokenStored[vault][to];
        if (toUserYieldPerTokenStored != 0) {
            // to account has held PYTs before
            userAccruedYield[vault][to] = _getClaimableYieldAmount(
                vault,
                pyt,
                to,
                updatedYieldPerToken,
                toUserYieldPerTokenStored
            );
        }
        userYieldPerTokenStored[vault][to] = updatedYieldPerToken + 1;
    }

    /// -----------------------------------------------------------------------
    /// Owner functions
    /// -----------------------------------------------------------------------

    function ownerSetProtocolFee(ProtocolFeeInfo calldata protocolFeeInfo_)
        external
        onlyOwner
    {
        if (
            protocolFeeInfo_.fee != 0 &&
            protocolFeeInfo_.recipient == address(0)
        ) {
            revert Error_ProtocolFeeRecipientIsZero();
        }
        protocolFeeInfo = protocolFeeInfo_;

        emit SetProtocolFee(protocolFeeInfo_);
    }

    /// -----------------------------------------------------------------------
    /// Internal utilities
    /// -----------------------------------------------------------------------

    /// @dev Updates the yield earned globally and for a particular user.
    function _accrueYield(
        address vault,
        PerpetualYieldToken pyt,
        address user,
        uint8 underlyingDecimals
    ) internal virtual {
        uint256 updatedPricePerVaultShare = getPricePerVaultShare(vault);
        uint256 updatedYieldPerToken = _computeYieldPerToken(
            vault,
            pyt,
            updatedPricePerVaultShare,
            underlyingDecimals
        );
        uint256 userYieldPerTokenStored_ = userYieldPerTokenStored[vault][user];
        if (userYieldPerTokenStored_ != 0) {
            userAccruedYield[vault][user] = _getClaimableYieldAmount(
                vault,
                pyt,
                user,
                updatedYieldPerToken,
                userYieldPerTokenStored_
            );
        }
        yieldPerTokenStored[vault] = updatedYieldPerToken;
        pricePerVaultShareStored[vault] = updatedPricePerVaultShare;
        userYieldPerTokenStored[vault][user] = updatedYieldPerToken + 1;
    }

    /// @dev Returns the amount of yield claimable by a PerpetualYieldToken holder from a vault.
    /// Assumes userYieldPerTokenStored_ != 0.
    function _getClaimableYieldAmount(
        address vault,
        PerpetualYieldToken pyt,
        address user,
        uint256 updatedYieldPerToken,
        uint256 userYieldPerTokenStored_
    ) internal view virtual returns (uint256) {
        unchecked {
            // the stored value is shifted by one
            uint256 actualUserYieldPerToken = userYieldPerTokenStored_ - 1;

            // updatedYieldPerToken - actualUserYieldPerToken won't underflow since we check updatedYieldPerToken > actualUserYieldPerToken
            // + userAccruedYield[vault][user] won't overflow since the sum is at most the totalSupply of the vault's underlying, which
            // is at most 256 bits.
            return
                FullMath.mulDiv(
                    pyt.balanceOf(user),
                    updatedYieldPerToken > actualUserYieldPerToken
                        ? updatedYieldPerToken - actualUserYieldPerToken
                        : 0,
                    PRECISION
                ) + userAccruedYield[vault][user];
        }
    }

    /// @dev Deposits underlying tokens into a vault
    /// @param underlying The underlying token to deposit
    /// @param underlyingAmount The amount of tokens to deposit
    /// @param vault The vault to deposit into
    function _depositIntoVault(
        ERC20 underlying,
        uint256 underlyingAmount,
        address vault
    ) internal virtual;

    /// @dev Withdraws underlying tokens from a vault
    /// @param recipient The recipient of the underlying tokens
    /// @param vault The vault to withdraw from
    /// @param underlyingAmount The amount of tokens to withdraw
    /// @param underlyingDecimals The number of decimals used by the underlying token
    /// @param checkBalance Set to true to withdraw the entire balance if we're trying
    /// to withdraw more than the balance (due to rounding errors)
    function _withdrawFromVault(
        address recipient,
        address vault,
        uint256 underlyingAmount,
        uint8 underlyingDecimals,
        bool checkBalance
    ) internal virtual;

    /// @dev Converts a vault share amount into an equivalent underlying asset amount
    function _vaultSharesAmountToUnderlyingAmount(
        address vault,
        uint256 vaultSharesAmount,
        uint8 underlyingDecimals
    ) internal view virtual returns (uint256);

    /// @dev Converts an underlying asset amount into an equivalent vault shares amount
    function _underlyingAmountToVaultSharesAmount(
        address vault,
        uint256 underlyingAmount,
        uint8 underlyingDecimals
    ) internal view virtual returns (uint256);

    /// @dev Computes the latest yieldPerToken value for a vault.
    function _computeYieldPerToken(
        address vault,
        PerpetualYieldToken pyt,
        uint256 updatedPricePerVaultShare,
        uint8 underlyingDecimals
    ) internal view virtual returns (uint256);
}
