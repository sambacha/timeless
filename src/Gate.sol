// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.4;

import {ERC20} from "solmate/tokens/ERC20.sol";
import {SafeTransferLib} from "solmate/utils/SafeTransferLib.sol";
import {Bytes32AddressLib} from "solmate/utils/Bytes32AddressLib.sol";

import {Factory} from "./Factory.sol";
import {FullMath} from "./lib/FullMath.sol";
import {YieldToken} from "./YieldToken.sol";

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
abstract contract Gate {
    /// -----------------------------------------------------------------------
    /// Library usage
    /// -----------------------------------------------------------------------

    using SafeTransferLib for ERC20;
    using Bytes32AddressLib for address;
    using Bytes32AddressLib for bytes32;

    /// -----------------------------------------------------------------------
    /// Errors
    /// -----------------------------------------------------------------------

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

    /// -----------------------------------------------------------------------
    /// Constants
    /// -----------------------------------------------------------------------

    /// @notice The precision used by yieldPerTokenStored
    uint256 internal constant PRECISION = 10**27;

    /// -----------------------------------------------------------------------
    /// Immutable parameters
    /// -----------------------------------------------------------------------

    Factory public immutable factory;

    /// -----------------------------------------------------------------------
    /// Storage variables
    /// -----------------------------------------------------------------------

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

    /// @notice The total supply of the yield tokens of a certain vault. Since PYTs and NYTs
    /// are always created in pairs, they always have the same total supply.
    /// @dev vault => value
    mapping(address => uint256) public yieldTokenTotalSupply;

    /// -----------------------------------------------------------------------
    /// Initialization
    /// -----------------------------------------------------------------------

    constructor(Factory factory_) {
        factory = factory_;
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

        /// -----------------------------------------------------------------------
        /// State updates
        /// -----------------------------------------------------------------------

        // mint PYT and NYT
        mintAmount = underlyingAmount;
        _enter(
            recipient,
            vault,
            getUnderlyingOfVault(vault).decimals(),
            underlyingAmount,
            getPricePerVaultShare(vault)
        );

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

        /// -----------------------------------------------------------------------
        /// State updates
        /// -----------------------------------------------------------------------

        // mint PYT and NYT
        uint8 underlyingDecimals = getUnderlyingOfVault(vault).decimals();
        uint256 updatedPricePerVaultShare = getPricePerVaultShare(vault);
        mintAmount = _vaultSharesAmountToUnderlyingAmount(
            vaultSharesAmount,
            underlyingDecimals,
            updatedPricePerVaultShare
        );
        _enter(
            recipient,
            vault,
            underlyingDecimals,
            mintAmount,
            updatedPricePerVaultShare
        );

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

        /// -----------------------------------------------------------------------
        /// State updates
        /// -----------------------------------------------------------------------

        // burn PYT and NYT
        uint8 underlyingDecimals = getUnderlyingOfVault(vault).decimals();
        uint256 updatedPricePerVaultShare = getPricePerVaultShare(vault);
        burnAmount = underlyingAmount;
        _exit(
            vault,
            underlyingDecimals,
            underlyingAmount,
            updatedPricePerVaultShare
        );

        /// -----------------------------------------------------------------------
        /// Effects
        /// -----------------------------------------------------------------------

        // withdraw underlying from vault to recipient
        // don't check balance since user can just withdraw slightly less
        // saves gas this way
        underlyingAmount = _withdrawFromVault(
            recipient,
            vault,
            underlyingAmount,
            underlyingDecimals,
            updatedPricePerVaultShare,
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

        /// -----------------------------------------------------------------------
        /// State updates
        /// -----------------------------------------------------------------------

        // burn PYT and NYT
        uint8 underlyingDecimals = getUnderlyingOfVault(vault).decimals();
        uint256 updatedPricePerVaultShare = getPricePerVaultShare(vault);
        burnAmount = _vaultSharesAmountToUnderlyingAmount(
            vaultSharesAmount,
            underlyingDecimals,
            updatedPricePerVaultShare
        );
        _exit(vault, underlyingDecimals, burnAmount, updatedPricePerVaultShare);

        /// -----------------------------------------------------------------------
        /// Effects
        /// -----------------------------------------------------------------------

        // transfer vault tokens to recipient
        ERC20(vault).safeTransfer(recipient, vaultSharesAmount);

        emit ExitToVaultShares(msg.sender, recipient, vault, vaultSharesAmount);
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
        /// State updates
        /// -----------------------------------------------------------------------

        // update storage variables and compute yield amount
        uint8 underlyingDecimals = getUnderlyingOfVault(vault).decimals();
        uint256 updatedPricePerVaultShare = getPricePerVaultShare(vault);
        yieldAmount = _claimYield(
            vault,
            underlyingDecimals,
            updatedPricePerVaultShare
        );

        // withdraw yield
        if (yieldAmount != 0) {
            /// -----------------------------------------------------------------------
            /// Effects
            /// -----------------------------------------------------------------------

            (uint8 fee, address protocolFeeRecipient) = factory
                .protocolFeeInfo();

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
                        protocolFee,
                        underlyingDecimals,
                        updatedPricePerVaultShare
                    );
                    if (protocolFee != 0) {
                        ERC20(vault).safeTransfer(
                            protocolFeeRecipient,
                            protocolFee
                        );
                    }
                } else {
                    // vault shares are not in ERC20
                    // withdraw underlying from vault
                    // checkBalance is set to false since we know there will
                    // still be nonnegligible vault shares after this
                    if (protocolFee != 0) {
                        _withdrawFromVault(
                            protocolFeeRecipient,
                            vault,
                            protocolFee,
                            underlyingDecimals,
                            updatedPricePerVaultShare,
                            false
                        );
                    }
                }
            }

            // withdraw underlying to recipient
            // checkBalance is set to true to prevent getting stuck
            // due to rounding errors
            yieldAmount = _withdrawFromVault(
                recipient,
                vault,
                yieldAmount,
                underlyingDecimals,
                updatedPricePerVaultShare,
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

        /// -----------------------------------------------------------------------
        /// State updates
        /// -----------------------------------------------------------------------

        // update storage variables and compute yield amount
        uint8 underlyingDecimals = getUnderlyingOfVault(vault).decimals();
        uint256 updatedPricePerVaultShare = getPricePerVaultShare(vault);
        yieldAmount = _claimYield(
            vault,
            underlyingDecimals,
            updatedPricePerVaultShare
        );

        // withdraw yield
        if (yieldAmount != 0) {
            /// -----------------------------------------------------------------------
            /// Effects
            /// -----------------------------------------------------------------------

            // convert yieldAmount to be denominated in vault shares
            yieldAmount = _underlyingAmountToVaultSharesAmount(
                yieldAmount,
                underlyingDecimals,
                updatedPricePerVaultShare
            );

            (uint8 fee, address protocolFeeRecipient) = factory
                .protocolFeeInfo();

            if (fee != 0) {
                uint256 protocolFee = (yieldAmount * fee) / 1000;
                unchecked {
                    // can't underflow since fee < 256
                    yieldAmount -= protocolFee;
                }

                ERC20(vault).safeTransfer(protocolFeeRecipient, protocolFee);
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
        returns (YieldToken)
    {
        return YieldToken(_computeYieldTokenAddress(vault, false));
    }

    /// @notice Returns the PerpetualYieldToken associated with a vault.
    /// @dev Returns non-zero value even if the contract hasn't been deployed yet.
    /// @param vault The vault to query
    /// @return The PerpetualYieldToken address
    function getPerpetualYieldTokenForVault(address vault)
        public
        view
        virtual
        returns (YieldToken)
    {
        return YieldToken(_computeYieldTokenAddress(vault, true));
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
        YieldToken pyt = getPerpetualYieldTokenForVault(vault);
        uint256 userYieldPerTokenStored_ = userYieldPerTokenStored[vault][user];
        if (userYieldPerTokenStored_ == 0) {
            // uninitialized account
            return 0;
        }
        return
            _getClaimableYieldAmount(
                vault,
                user,
                _computeYieldPerToken(
                    vault,
                    getPricePerVaultShare(vault),
                    pyt.decimals()
                ),
                userYieldPerTokenStored_,
                pyt.balanceOf(user)
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
        YieldToken pyt = getPerpetualYieldTokenForVault(vault);
        return
            _computeYieldPerToken(
                vault,
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
    /// @param fromBalance The token balance of the from account before the transfer
    /// @param toBalance The token balance of the to account before the transfer
    function beforePerpetualYieldTokenTransfer(
        address from,
        address to,
        uint256 amount,
        uint256 fromBalance,
        uint256 toBalance
    ) external virtual {
        /// -----------------------------------------------------------------------
        /// Validation
        /// -----------------------------------------------------------------------

        if (amount == 0) {
            return;
        }

        address vault = YieldToken(msg.sender).vault();
        YieldToken pyt = getPerpetualYieldTokenForVault(vault);
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
            updatedPricePerVaultShare,
            pyt.decimals()
        );
        yieldPerTokenStored[vault] = updatedYieldPerToken;
        pricePerVaultShareStored[vault] = updatedPricePerVaultShare;

        // we know the from account must have held PYTs before
        // so we will always accrue the yield earned by the from account
        uint256 fromClaimableYieldAmount = _getClaimableYieldAmount(
            vault,
            from,
            updatedYieldPerToken,
            userYieldPerTokenStored[vault][from],
            fromBalance
        );
        uint256 fromAccruedYield = FullMath.mulDiv(
            fromClaimableYieldAmount,
            fromBalance - amount,
            fromBalance
        );
        userAccruedYield[vault][from] = fromAccruedYield;
        userYieldPerTokenStored[vault][from] = updatedYieldPerToken + 1;

        // the to account might not have held PYTs before
        // we only accrue yield if they have
        uint256 toUserYieldPerTokenStored = userYieldPerTokenStored[vault][to];
        if (toUserYieldPerTokenStored != 0) {
            // to account has held PYTs before
            userAccruedYield[vault][to] =
                _getClaimableYieldAmount(
                    vault,
                    to,
                    updatedYieldPerToken,
                    toUserYieldPerTokenStored,
                    toBalance
                ) +
                fromClaimableYieldAmount -
                fromAccruedYield;
        } else {
            // to account hasn't held PYTs before
            userAccruedYield[vault][to] =
                fromClaimableYieldAmount -
                fromAccruedYield;
        }
        userYieldPerTokenStored[vault][to] = updatedYieldPerToken + 1;
    }

    /// -----------------------------------------------------------------------
    /// Internal utilities
    /// -----------------------------------------------------------------------

    /// @dev Updates the yield earned globally and for a particular user.
    function _accrueYield(
        address vault,
        YieldToken pyt,
        address user,
        uint8 underlyingDecimals,
        uint256 updatedPricePerVaultShare
    ) internal virtual {
        uint256 updatedYieldPerToken = _computeYieldPerToken(
            vault,
            updatedPricePerVaultShare,
            underlyingDecimals
        );
        uint256 userYieldPerTokenStored_ = userYieldPerTokenStored[vault][user];
        if (userYieldPerTokenStored_ != 0) {
            userAccruedYield[vault][user] = _getClaimableYieldAmount(
                vault,
                user,
                updatedYieldPerToken,
                userYieldPerTokenStored_,
                pyt.balanceOf(user)
            );
        }
        yieldPerTokenStored[vault] = updatedYieldPerToken;
        pricePerVaultShareStored[vault] = updatedPricePerVaultShare;
        userYieldPerTokenStored[vault][user] = updatedYieldPerToken + 1;
    }

    /// @dev Computes the address of PYTs and NYTs using CREATE2.
    function _computeYieldTokenAddress(
        address vault,
        bool isPerpetualYieldToken
    ) internal view virtual returns (address) {
        return
            keccak256(
                abi.encodePacked(
                    // Prefix:
                    bytes1(0xFF),
                    // Creator:
                    address(factory),
                    // Salt:
                    bytes32(0),
                    // Bytecode hash:
                    keccak256(
                        abi.encodePacked(
                            // Deployment bytecode:
                            type(YieldToken).creationCode,
                            // Constructor arguments:
                            abi.encode(
                                address(this),
                                vault,
                                isPerpetualYieldToken
                            )
                        )
                    )
                )
            ).fromLast20Bytes(); // Convert the CREATE2 hash into an address.
    }

    /// @dev Mints PYTs and NYTs to the recipient given the amount of underlying deposited.
    function _enter(
        address recipient,
        address vault,
        uint8 underlyingDecimals,
        uint256 underlyingAmount,
        uint256 updatedPricePerVaultShare
    ) internal virtual {
        YieldToken nyt = getNegativeYieldTokenForVault(vault);
        if (address(nyt).code.length == 0) {
            // token pair hasn't been deployed yet
            // do the deployment now
            // only need to check nyt since nyt and pyt are always deployed in pairs
            factory.deployYieldTokenPair(this, vault);
        }
        YieldToken pyt = getPerpetualYieldTokenForVault(vault);

        /// -----------------------------------------------------------------------
        /// State updates
        /// -----------------------------------------------------------------------

        // accrue yield
        _accrueYield(
            vault,
            pyt,
            recipient,
            underlyingDecimals,
            updatedPricePerVaultShare
        );

        // mint NYTs and PYTs
        yieldTokenTotalSupply[vault] += underlyingAmount;
        nyt.gateMint(recipient, underlyingAmount);
        pyt.gateMint(recipient, underlyingAmount);
    }

    /// @dev Burns PYTs and NYTs from msg.sender given the amount of underlying withdrawn.
    function _exit(
        address vault,
        uint8 underlyingDecimals,
        uint256 underlyingAmount,
        uint256 updatedPricePerVaultShare
    ) internal virtual {
        YieldToken nyt = getNegativeYieldTokenForVault(vault);
        YieldToken pyt = getPerpetualYieldTokenForVault(vault);
        if (address(nyt).code.length == 0) {
            revert Error_TokenPairNotDeployed();
        }

        /// -----------------------------------------------------------------------
        /// State updates
        /// -----------------------------------------------------------------------

        // accrue yield
        _accrueYield(
            vault,
            pyt,
            msg.sender,
            underlyingDecimals,
            updatedPricePerVaultShare
        );

        // burn NYTs and PYTs
        unchecked {
            // Cannot underflow because a user's balance
            // will never be larger than the total supply.
            yieldTokenTotalSupply[vault] -= underlyingAmount;
        }
        nyt.gateBurn(msg.sender, underlyingAmount);
        pyt.gateBurn(msg.sender, underlyingAmount);
    }

    /// @dev Updates storage variables for when a PYT holder claims the accrued yield.
    function _claimYield(
        address vault,
        uint8 underlyingDecimals,
        uint256 updatedPricePerVaultShare
    ) internal virtual returns (uint256 yieldAmount) {
        /// -----------------------------------------------------------------------
        /// Validation
        /// -----------------------------------------------------------------------

        YieldToken pyt = getPerpetualYieldTokenForVault(vault);
        if (address(pyt).code.length == 0) {
            revert Error_TokenPairNotDeployed();
        }

        /// -----------------------------------------------------------------------
        /// State updates
        /// -----------------------------------------------------------------------

        // accrue yield
        uint256 updatedYieldPerToken = _computeYieldPerToken(
            vault,
            updatedPricePerVaultShare,
            underlyingDecimals
        );
        uint256 userYieldPerTokenStored_ = userYieldPerTokenStored[vault][
            msg.sender
        ];
        if (userYieldPerTokenStored_ != 0) {
            yieldAmount = _getClaimableYieldAmount(
                vault,
                msg.sender,
                updatedYieldPerToken,
                userYieldPerTokenStored_,
                pyt.balanceOf(msg.sender)
            );
        }
        yieldPerTokenStored[vault] = updatedYieldPerToken;
        pricePerVaultShareStored[vault] = updatedPricePerVaultShare;
        userYieldPerTokenStored[vault][msg.sender] = updatedYieldPerToken + 1;
        if (yieldAmount != 0) {
            userAccruedYield[vault][msg.sender] = 0;
        }
    }

    /// @dev Returns the amount of yield claimable by a PerpetualYieldToken holder from a vault.
    /// Assumes userYieldPerTokenStored_ != 0.
    function _getClaimableYieldAmount(
        address vault,
        address user,
        uint256 updatedYieldPerToken,
        uint256 userYieldPerTokenStored_,
        uint256 userPYTBalance
    ) internal view virtual returns (uint256) {
        unchecked {
            // the stored value is shifted by one
            uint256 actualUserYieldPerToken = userYieldPerTokenStored_ - 1;

            // updatedYieldPerToken - actualUserYieldPerToken won't underflow since we check updatedYieldPerToken > actualUserYieldPerToken
            // + userAccruedYield[vault][user] won't overflow since the sum is at most the totalSupply of the vault's underlying, which
            // is at most 256 bits.
            return
                FullMath.mulDiv(
                    userPYTBalance,
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
    /// @param pricePerVaultShare The latest price per vault share value
    /// @param checkBalance Set to true to withdraw the entire balance if we're trying
    /// to withdraw more than the balance (due to rounding errors)
    /// @return withdrawnUnderlyingAmount The amount of underlying tokens withdrawn
    function _withdrawFromVault(
        address recipient,
        address vault,
        uint256 underlyingAmount,
        uint8 underlyingDecimals,
        uint256 pricePerVaultShare,
        bool checkBalance
    ) internal virtual returns (uint256 withdrawnUnderlyingAmount);

    /// @dev Converts a vault share amount into an equivalent underlying asset amount
    function _vaultSharesAmountToUnderlyingAmount(
        uint256 vaultSharesAmount,
        uint8 underlyingDecimals,
        uint256 pricePerVaultShare
    ) internal pure virtual returns (uint256);

    /// @dev Converts an underlying asset amount into an equivalent vault shares amount
    function _underlyingAmountToVaultSharesAmount(
        uint256 underlyingAmount,
        uint8 underlyingDecimals,
        uint256 pricePerVaultShare
    ) internal pure virtual returns (uint256);

    /// @dev Computes the latest yieldPerToken value for a vault.
    function _computeYieldPerToken(
        address vault,
        uint256 updatedPricePerVaultShare,
        uint8 underlyingDecimals
    ) internal view virtual returns (uint256);
}
