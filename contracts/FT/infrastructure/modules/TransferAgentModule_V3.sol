// SPDX-License-Identifier: Business Source License 1.1
pragma solidity 0.8.18;

import {AccessControlEnumerableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlEnumerableUpgradeable.sol";
import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {EnumerableSetUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/structs/EnumerableSetUpgradeable.sol";
import {BaseUpgradeableModule} from "../../BaseUpgradeableModule.sol";

import {IAuthorization} from "../../../../interfaces/IAuthorization.sol";
import {IHoldings} from "../../../../interfaces/IHoldings.sol";
import {IAdminTransfer} from "../../../../interfaces/IAdminTransfer.sol";
import {ITransactionStorage} from "../../../../interfaces/TransactionIfaces.sol";
import {IExtendedTransactionDetail} from "../../../../interfaces/TransactionIfaces.sol";
import {ITransferAgent} from "../../../../interfaces/ITransferAgent.sol";
import {IRecovery} from "../../../../interfaces/IRecovery.sol";
import {IAccountManager} from "../../../../interfaces/IAccountManager.sol";
import {MoneyMarketFund} from "../../../../MoneyMarketFund.sol";
import {ModuleRegistry} from "../../../ModuleRegistry.sol";
import {TokenRegistry} from "../../../../infrastructure/TokenRegistry.sol";

contract TransferAgentModule_V3 is
    BaseUpgradeableModule,
    AccessControlEnumerableUpgradeable,
    ITransferAgent,
    IRecovery
{
    bytes32 public constant MODULE_ID = keccak256("MODULE_TRANSFER_AGENT");
    bytes32 public constant ROLE_MODULE_OWNER = keccak256("ROLE_MODULE_OWNER");
    bytes32 constant AUTHORIZATION_MODULE = keccak256("MODULE_AUTHORIZATION");
    bytes32 constant TRANSACTIONAL_MODULE = keccak256("MODULE_TRANSACTIONAL");

    uint256 public constant MAX_ACCOUNT_PAGE_SIZE = 10;

    TokenRegistry tokenRegistry;
    MoneyMarketFund moneyMarketFund;
    /// @dev The Id of the token associated with the settlement and div distribution of this contract
    /// At the moment only a default token Id can be provided during contract initialization
    /// but in the future more tokens could be used using the token registry
    string tokenId;

    // *********************** Events *********************** //
    // ****************************************************** //

    /**
     * @dev This is emitted when dividends are paid to the shareholder,
     * in the very unlikely scenario of rate being lower than 0 the dividend
     * will be deducted from the shareholder's balance instead:
     */
    event DividendDistributed(
        address indexed account,
        uint256 indexed date,
        int256 rate,
        uint256 price,
        uint256 shares
    );
    /// @dev This is emitted when a shareholder request is settled:
    event TransactionSettled(
        address indexed account,
        uint256 indexed date,
        uint8 indexed transactionType,
        bytes32 transactionId,
        uint256 price,
        uint256 amount,
        uint256 shares
    );
    /// @dev This is emitted when a share transfer is settled:
    event TransferSettled(
        address indexed from,
        address indexed to,
        uint256 indexed date,
        uint8 transactionType,
        bytes32 transactionId,
        uint256 price,
        uint256 shares
    );
    /// @dev This is emitted when a manual adjustment of the balance is performed by the TA:
    event BalanceAdjusted(address indexed account, uint256 amount, string memo);
    /// @dev This is emmited when the entire balance of an account is recovered by the TA:
    event AccountRecovered(
        address indexed fromAccount,
        address indexed toAccount,
        uint256 amount,
        string memo
    );
    /// @dev This is emmited when a partial balance amount of an account is recovered by the TA:
    event AssetRecovered(
        address indexed fromAccount,
        address indexed toAccount,
        uint256 amount,
        string memo
    );

    // ---------------------- Modifiers ----------------------  //

    modifier onlyAdmin() {
        require(
            IAuthorization(modules.getModuleAddress(AUTHORIZATION_MODULE))
                .isAdminAccount(msg.sender),
            "CALLER_IS_NOT_AN_ADMIN"
        );
        _;
    }

    modifier onlyWhenShareholderExists(address account) {
        require(
            IAuthorization(modules.getModuleAddress(AUTHORIZATION_MODULE))
                .isAccountAuthorized(account),
            "SHAREHOLDER_DOES_NOT_EXISTS"
        );
        _;
    }

    // -------------------- Dividends --------------------  //

    modifier onlyWithValidRate(int256 rate) {
        require(rate != 0, "INVALID_DIV_RATE");
        _;
    }

    // ---------------- Transactions ----------------  //

    modifier onlyValidPaginationSize(
        uint256 arrayLength,
        uint256 maxArraySize
    ) {
        require(arrayLength <= maxArraySize, "INVALID_PAGINATION_SIZE");
        _;
    }

    modifier whenTransactionsExist(address account) {
        if (
            ITransactionStorage(modules.getModuleAddress(TRANSACTIONAL_MODULE))
                .hasTransactions(account)
        ) {
            _;
        }
    }

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function _authorizeUpgrade(
        address newImplementation
    ) internal virtual override onlyRole(ROLE_MODULE_OWNER) {}

    function getVersion() external pure virtual override returns (uint8) {
        return 3;
    }

    function adjustBalance(
        address account,
        uint256 currentBalance,
        uint256 newBalance,
        string memory memo
    ) external virtual override onlyAdmin onlyWhenShareholderExists(account) {
        require(
            currentBalance == moneyMarketFund.balanceOf(account),
            "CURRENT_BALANCE_MISMATCH"
        );
        require(
            newBalance != moneyMarketFund.balanceOf(account),
            "NO_ADJUSTMENT_REQUIRED"
        );

        if (currentBalance > newBalance) {
            moneyMarketFund.burnShares(account, (currentBalance - newBalance));
            emit BalanceAdjusted(account, (currentBalance - newBalance), memo);
        } else {
            moneyMarketFund.mintShares(account, (newBalance - currentBalance));
            emit BalanceAdjusted(account, (newBalance - currentBalance), memo);
        }
        moneyMarketFund.updateHolderInList(account);
    }

    /**
     * @notice Distributes dividends to the account if it has holdings.
     *
     * The amount of shares to distribute in the form of divideds are calculated as follows:
     *
     *      Share dividends = (account's balance * rate) / price
     *
     * This operation will mint or burn shares according to the rate provided.
     *      If rate > 0 it will mint shares
     *      If rate < 0 it will burn shares
     *
     * @param accounts The address of the shareholders' accounts
     * @param date The date of the request as a UNIX timestamp
     * @param rate The rate for the given shareholder
     * @param price The NAV price per share
     *
     */
    function distributeDividends(
        address[] memory accounts,
        uint256 date,
        int256 rate,
        uint256 price
    )
        external
        virtual
        override
        onlyAdmin
        onlyWithValidRate(rate)
        onlyValidPaginationSize(accounts.length, MAX_ACCOUNT_PAGE_SIZE)
    {
        moneyMarketFund.updateLastKnownPrice(price);
        for (uint i = 0; i < accounts.length; ) {
            _processDividends(accounts[i], date, rate, price);
            unchecked {
                i++;
            }
        }
    }

    /**
     * @notice Distributes dividends and settles existing requests prior to the specified date for the given account.
     *
     * @param accounts The address of the shareholders' accounts
     * @param date The date of the request as a UNIX timestamp
     * @param rate The rate
     * @param price The NAV price per share
     *
     */
    function endOfDay(
        address[] memory accounts,
        uint256 date,
        int256 rate,
        uint256 price
    )
        external
        virtual
        override
        onlyAdmin
        onlyWithValidRate(rate)
        onlyValidPaginationSize(accounts.length, MAX_ACCOUNT_PAGE_SIZE)
    {
        moneyMarketFund.updateLastKnownPrice(price);
        for (uint i = 0; i < accounts.length; ) {
            _processDividends(accounts[i], date, rate, price);
            _processSettlements(accounts[i], date, price);
            unchecked {
                i++;
            }
        }
    }

    /**
     * @notice Settles existing requests prior to the specified date for the given account.
     *
     * This operation will mint or burn shares according to the request type.
     *
     * @param accounts The address of the shareholders' accounts
     * @param date The date of the request as a UNIX timestamp
     * @param price The NAV price per share
     *
     */
    function settleTransactions(
        address[] memory accounts,
        uint256 date,
        uint256 price
    )
        external
        virtual
        override
        onlyAdmin
        onlyValidPaginationSize(accounts.length, MAX_ACCOUNT_PAGE_SIZE)
    {
        moneyMarketFund.updateLastKnownPrice(price);
        for (uint i = 0; i < accounts.length; ) {
            _processSettlements(accounts[i], date, price);
            unchecked {
                i++;
            }
        }
    }

    /**
     * @dev Recovers the entire balance of an account
     *
     * @param from the account holding the balance to recover
     * @param to the destination account to transfer the balance
     * @param memo a memo for the recovery operation
     */
    function recoverAccount(
        address from,
        address to,
        string memory memo
    ) external virtual override onlyAdmin {
        // Checks
        require(
            !ITransactionStorage(modules.getModuleAddress(TRANSACTIONAL_MODULE))
                .hasTransactions(from),
            "PENDING_TRANSACTIONS_EXIST"
        );
        require(
            moneyMarketFund.getShareHoldings(from) > 0,
            "ACCOUNT_HAS_NO_BALANCE"
        );
        uint256 balance = moneyMarketFund.getShareHoldings(from);

        // Effects & Interactions
        moneyMarketFund.burnShares(from, balance);
        moneyMarketFund.mintShares(to, balance);
        moneyMarketFund.updateHolderInList(from);
        moneyMarketFund.updateHolderInList(to);
        IAccountManager(modules.getModuleAddress(AUTHORIZATION_MODULE))
            .removeAccountPostRecovery(from, to);

        emit AccountRecovered(from, to, balance, memo);
    }

    /**
     * @dev Recovers a part of the balance of an account
     *
     * @param from the account holding the balance amount to recover
     * @param to the destination account to transfer the balance
     * @param memo a memo for the recovery operation
     */
    function recoverAsset(
        address from,
        address to,
        uint256 amount,
        string memory memo
    ) external virtual override onlyAdmin {
        // Checks
        require(
            IAuthorization(modules.getModuleAddress(AUTHORIZATION_MODULE))
                .isAccountAuthorized(from) &&
                IAuthorization(modules.getModuleAddress(AUTHORIZATION_MODULE))
                    .isAccountAuthorized(to),
            "SHAREHOLDER_DOES_NOT_EXISTS"
        );

        uint256 balance = moneyMarketFund.getShareHoldings(from);
        require(balance >= amount, "NOT_ENOUGH_BALANCE");

        // Effects & Interactions
        moneyMarketFund.burnShares(from, amount);
        moneyMarketFund.mintShares(to, amount);
        moneyMarketFund.updateHolderInList(from);
        moneyMarketFund.updateHolderInList(to);

        emit AssetRecovered(from, to, amount, memo);
    }

    // -------------------- Dividends --------------------  //

    function _payDividend(
        address account,
        int256 rate,
        uint256 dividendShares
    ) internal virtual {
        moneyMarketFund.mintShares(account, dividendShares);
    }

    function _handleNegativeYield(
        address account,
        int256 rate,
        uint256 dividendShares
    ) internal {
        uint256 negativeYield;
        if (dividendShares < moneyMarketFund.balanceOf(account)) {
            negativeYield = dividendShares;
        } else {
            negativeYield = moneyMarketFund.balanceOf(account);
        }
        moneyMarketFund.burnShares(account, negativeYield);
    }

    // -------------------- Transactions --------------------  //

    function _processSettlements(
        address account,
        uint256 date,
        uint256 price
    ) internal virtual whenTransactionsExist(account) {
        bytes32[] memory pendingTxs = ITransactionStorage(
            modules.getModuleAddress(TRANSACTIONAL_MODULE)
        ).getAccountTransactions(account);
        for (uint256 i = 0; i < pendingTxs.length; ) {
            bytes32 txId = pendingTxs[i];
            (
                uint8 txType,
                address source,
                address destination,
                uint256 txDate,
                uint256 amount,

            ) = IExtendedTransactionDetail(
                    modules.getModuleAddress(TRANSACTIONAL_MODULE)
                ).getExtendedTransactionDetail(txId);
            require(
                _isTypeSupported(ITransactionStorage.TransactionType(txType)),
                "INVALID_TRANSACTION_TYPE"
            );
            if (txDate <= date) {
                if (
                    _isLiquidation(ITransactionStorage.TransactionType(txType))
                ) {
                    _handleLiquidation(
                        account,
                        date,
                        amount,
                        price,
                        txId,
                        ITransactionStorage.TransactionType(txType)
                    );
                } else if (
                    _isPurchase(ITransactionStorage.TransactionType(txType))
                ) {
                    _handlePurchase(
                        account,
                        date,
                        amount,
                        price,
                        txId,
                        ITransactionStorage.TransactionType(txType)
                    );
                } else if (
                    ITransactionStorage.TransactionType(txType) ==
                    ITransactionStorage.TransactionType.SHARE_TRANSFER
                ) {
                    IAdminTransfer(tokenRegistry.getTokenAddress(tokenId))
                        .transferShares(source, destination, amount);
                    // Also update destination account for this TX type
                    // as a transfer changes the state of both accounts.
                    // For transfers account and source are the samme address.
                    moneyMarketFund.updateHolderInList(destination);
                    emit TransferSettled(
                        source,
                        destination,
                        date,
                        txType,
                        txId,
                        price,
                        amount // shares
                    );
                }
                moneyMarketFund.updateHolderInList(account);
                ITransactionStorage(
                    modules.getModuleAddress(TRANSACTIONAL_MODULE)
                ).clearTransactionStorage(account, txId);
            }
            unchecked {
                i++;
            }
        }
        ITransactionStorage(modules.getModuleAddress(TRANSACTIONAL_MODULE))
            .unlistFromAccountsWithPendingTransactions(account);
    }

    function _processDividends(
        address account,
        uint256 date,
        int256 rate,
        uint256 price
    ) internal virtual {
        if (moneyMarketFund.hasHoldings(account)) {
            uint256 dividendAmount = moneyMarketFund.balanceOf(account) *
                uint256(abs(rate));
            uint256 dividendShares = dividendAmount / price;

            // a valid rate for this internal function (rate != 0) is verified
            // in the calling function via the  'onlyWithValidRate' modifier
            if (rate > 0) {
                _payDividend(account, rate, dividendShares);
            } else {
                // handle very unlikely scenario if occurs
                _handleNegativeYield(account, rate, dividendShares);
            }
            moneyMarketFund.removeEmptyHolderFromList(account);

            emit DividendDistributed(
                account,
                date,
                rate,
                price,
                dividendShares
            );
        }
    }

    function _handleLiquidation(
        address account,
        uint256 date,
        uint256 amount,
        uint256 price,
        bytes32 txId,
        ITransactionStorage.TransactionType txType
    ) internal virtual {
        uint256 scaleFactor = moneyMarketFund.NUMBER_SCALE_FACTOR();
        if (txType == ITransactionStorage.TransactionType.FULL_LIQUIDATION) {
            uint256 lastBalance = moneyMarketFund.balanceOf(account);
            moneyMarketFund.burnShares(account, lastBalance);
            emit TransactionSettled(
                account,
                date,
                uint8(txType),
                txId,
                price,
                (lastBalance * price) / scaleFactor,
                lastBalance
            );
        } else {
            uint256 shares = _getQuantityOfTokens(scaleFactor, amount, price);
            moneyMarketFund.burnShares(account, shares);
            emit TransactionSettled(
                account,
                date,
                uint8(txType),
                txId,
                price,
                amount,
                shares
            );
        }
    }

    function _handlePurchase(
        address account,
        uint256 date,
        uint256 amount,
        uint256 price,
        bytes32 txId,
        ITransactionStorage.TransactionType txType
    ) internal virtual {
        uint256 shares = _getQuantityOfTokens(
            moneyMarketFund.NUMBER_SCALE_FACTOR(),
            amount,
            price
        );
        emit TransactionSettled(
            account,
            date,
            uint8(txType),
            txId,
            price,
            amount,
            shares
        );
        moneyMarketFund.mintShares(account, shares);
    }

    function _isTypeSupported(
        ITransactionStorage.TransactionType txType
    ) internal pure virtual returns (bool) {
        return (txType == ITransactionStorage.TransactionType.AIP ||
            txType == ITransactionStorage.TransactionType.CASH_PURCHASE ||
            txType == ITransactionStorage.TransactionType.CASH_LIQUIDATION ||
            txType == ITransactionStorage.TransactionType.FULL_LIQUIDATION ||
            txType == ITransactionStorage.TransactionType.SHARE_TRANSFER);
    }

    function _isPurchase(
        ITransactionStorage.TransactionType txType
    ) internal pure virtual returns (bool) {
        return (txType == ITransactionStorage.TransactionType.AIP ||
            txType == ITransactionStorage.TransactionType.CASH_PURCHASE);
    }

    function _isLiquidation(
        ITransactionStorage.TransactionType txType
    ) internal pure virtual returns (bool) {
        return (txType ==
            ITransactionStorage.TransactionType.CASH_LIQUIDATION ||
            txType == ITransactionStorage.TransactionType.FULL_LIQUIDATION);
    }

    // ------------------------------------------------------------------- //

    function _getQuantityOfTokens(
        uint256 scaleFactor,
        uint256 amount,
        uint256 price
    ) internal pure virtual returns (uint256) {
        return ((amount * scaleFactor) / price);
    }

    function abs(int x) internal pure virtual returns (int) {
        return x >= 0 ? x : -x;
    }
}
