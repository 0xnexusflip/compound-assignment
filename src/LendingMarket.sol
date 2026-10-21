// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {IERC20} from "./interfaces/IERC20.sol";
import {IPriceOracle} from "./interfaces/IPriceOracle.sol";

/**
 * @title LendingMarket
 * @notice Single-collateral money market. Suppliers deposit the base asset and earn interest;
 *         borrowers post collateral and draw the base asset against it. Balances are tracked as
 *         principal and scaled by a pair of global indices that advance with accrued interest.
 *
 * @dev This contract is deployed behind a TransparentUpgradeableProxy. Live markets hold real
 *      user balances in the storage layout below.
 *
 *      Scaling: all values are 1e18-fixed-point unless stated otherwise. Collateral prices are
 *      quoted by the oracle in base-asset terms, also 1e18.
 */
contract LendingMarket {
    // -------------------------------------------------------------------------------------------
    // Constants
    // -------------------------------------------------------------------------------------------

    uint256 internal constant FACTOR = 1e18;

    /// @dev Oldest oracle answer the market accepts when no explicit maximum age is configured.
    uint256 internal constant DEFAULT_MAX_PRICE_AGE = 1 days;

    // -------------------------------------------------------------------------------------------
    // Storage
    // -------------------------------------------------------------------------------------------

    // --- roles and wiring ---
    address public admin;
    address public pauseGuardian;
    IPriceOracle public oracle;
    IERC20 public baseToken;
    IERC20 public collateralToken;

    // --- accrual state ---
    uint256 public baseBorrowIndex;
    uint256 public baseSupplyIndex;
    uint256 public lastAccrualTime;

    // --- market totals (principal terms) ---
    uint256 public totalSupplyPrincipal;
    uint256 public totalBorrowPrincipal;
    uint256 public totalCollateral;

    // --- risk parameters ---
    uint256 public collateralFactor;
    uint256 public liquidationIncentive;
    uint256 public borrowRatePerSecond;

    // --- per-account state ---
    mapping(address => uint256) public supplyPrincipal;
    mapping(address => uint256) public borrowPrincipal;
    mapping(address => uint256) public collateralBalance;

    // --- circuit breaker ---
    bool public paused;

    bool private _initialized;

    // --- appended after the live layout, never reorder the slots above ---

    /// @dev Zero means DEFAULT_MAX_PRICE_AGE, so an upgraded proxy is protected without a reinitializer.
    uint256 private _maxPriceAge;

    /// @notice Debt written off at liquidation because no collateral was left to back it, in base units.
    uint256 public badDebt;

    /// @notice Admin nominated by setAdmin, takes over when it calls acceptAdmin.
    address public pendingAdmin;

    // -------------------------------------------------------------------------------------------
    // Events
    // -------------------------------------------------------------------------------------------

    event Supply(address indexed account, uint256 amount);
    event Withdraw(address indexed account, uint256 amount);
    event SupplyCollateral(address indexed account, uint256 amount);
    event WithdrawCollateral(address indexed account, uint256 amount);
    event Borrow(address indexed account, uint256 amount);
    event Repay(address indexed account, uint256 amount);
    event Liquidate(address indexed liquidator, address indexed borrower, uint256 repaid, uint256 seized);
    event OracleUpdated(address indexed newOracle);
    event ParametersUpdated(uint256 collateralFactor, uint256 liquidationIncentive, uint256 borrowRate);
    event PausedSet(bool paused);
    event PauseGuardianUpdated(address indexed newGuardian);
    event AdminTransferStarted(address indexed newAdmin);
    event AdminTransferred(address indexed newAdmin);
    event MaxPriceAgeUpdated(uint256 maxPriceAge);
    event BadDebtWrittenOff(address indexed borrower, uint256 amount);

    // -------------------------------------------------------------------------------------------
    // Modifiers
    // -------------------------------------------------------------------------------------------

    modifier onlyAdmin() {
        require(msg.sender == admin, "not admin");
        _;
    }

    modifier onlyGuardian() {
        require(msg.sender == pauseGuardian || msg.sender == admin, "not guardian");
        _;
    }

    modifier whenNotPaused() {
        require(!paused, "paused");
        _;
    }

    // -------------------------------------------------------------------------------------------
    // Initialization
    // -------------------------------------------------------------------------------------------

    function initialize(
        address admin_,
        address pauseGuardian_,
        address oracle_,
        address baseToken_,
        address collateralToken_,
        uint256 collateralFactor_,
        uint256 liquidationIncentive_,
        uint256 borrowRatePerSecond_
    ) external {
        require(!_initialized, "already initialized");
        _initialized = true;

        admin = admin_;
        pauseGuardian = pauseGuardian_;
        oracle = IPriceOracle(oracle_);
        baseToken = IERC20(baseToken_);
        collateralToken = IERC20(collateralToken_);

        collateralFactor = collateralFactor_;
        liquidationIncentive = liquidationIncentive_;
        borrowRatePerSecond = borrowRatePerSecond_;

        baseBorrowIndex = FACTOR;
        baseSupplyIndex = FACTOR;
        lastAccrualTime = block.timestamp;
    }

    // -------------------------------------------------------------------------------------------
    // Interest accrual
    // -------------------------------------------------------------------------------------------

    /// @notice Advances both indices to the current block timestamp.
    function accrueInterest() public {
        uint256 elapsed = block.timestamp - lastAccrualTime;
        if (elapsed == 0) return;

        uint256 interest = borrowRatePerSecond * elapsed;

        uint256 borrowsBefore = presentValueBorrow(totalBorrowPrincipal);
        uint256 suppliesBefore = presentValueSupply(totalSupplyPrincipal);

        baseBorrowIndex += (baseBorrowIndex * interest) / FACTOR;

        if (suppliesBefore > 0) {
            // Donated base lets borrows exceed supplies. Only the supplied value earns, so the supply
            // index can never grow faster than the borrow index and cannot be inflated by a tiny supplier.
            uint256 earning = borrowsBefore > suppliesBefore ? suppliesBefore : borrowsBefore;
            uint256 accruedToSuppliers = (earning * interest) / FACTOR;
            baseSupplyIndex += (baseSupplyIndex * accruedToSuppliers) / suppliesBefore;
        }

        lastAccrualTime = block.timestamp;
    }

    // -------------------------------------------------------------------------------------------
    // Supplier actions
    // -------------------------------------------------------------------------------------------

    function supply(uint256 amount) external whenNotPaused {
        require(amount > 0, "zero amount");
        accrueInterest();

        uint256 principal = _principalForSupply(amount);
        require(principal > 0, "zero principal");
        supplyPrincipal[msg.sender] += principal;
        totalSupplyPrincipal += principal;

        _transferIn(baseToken, amount);

        emit Supply(msg.sender, amount);
    }

    function withdraw(uint256 amount) external whenNotPaused {
        require(amount > 0, "zero amount");
        accrueInterest();

        uint256 principal = _principalForSupplyRoundUp(amount);
        require(supplyPrincipal[msg.sender] >= principal, "insufficient balance");

        supplyPrincipal[msg.sender] -= principal;
        totalSupplyPrincipal -= principal;

        _transferOut(baseToken, amount);

        emit Withdraw(msg.sender, amount);
    }

    // -------------------------------------------------------------------------------------------
    // Borrower actions
    // -------------------------------------------------------------------------------------------

    // Adding collateral only reduces risk, so it stays open while the market is paused.
    function supplyCollateral(uint256 amount) external {
        require(amount > 0, "zero amount");

        collateralBalance[msg.sender] += amount;
        totalCollateral += amount;

        _transferIn(collateralToken, amount);

        emit SupplyCollateral(msg.sender, amount);
    }

    function withdrawCollateral(uint256 amount) external whenNotPaused {
        require(amount > 0, "zero amount");
        accrueInterest();
        require(collateralBalance[msg.sender] >= amount, "insufficient collateral");

        collateralBalance[msg.sender] -= amount;
        totalCollateral -= amount;

        require(isHealthy(msg.sender), "would be undercollateralized");

        _transferOut(collateralToken, amount);

        emit WithdrawCollateral(msg.sender, amount);
    }

    function borrow(uint256 amount) external whenNotPaused {
        require(amount > 0, "zero amount");
        accrueInterest();

        uint256 principal = _principalForBorrowRoundUp(amount);
        borrowPrincipal[msg.sender] += principal;
        totalBorrowPrincipal += principal;

        require(isHealthy(msg.sender), "would be undercollateralized");

        _transferOut(baseToken, amount);

        emit Borrow(msg.sender, amount);
    }

    function repay(uint256 amount) external {
        require(amount > 0, "zero amount");
        accrueInterest();

        uint256 owed = borrowBalanceOf(msg.sender);
        if (amount > owed) amount = owed;

        // A full repayment clears the whole principal. Converting owed back to principal rounds down
        // and can strand one unit that no later call can clear.
        uint256 principal = amount == owed ? borrowPrincipal[msg.sender] : _principalForBorrow(amount);

        borrowPrincipal[msg.sender] -= principal;
        totalBorrowPrincipal -= principal;

        _transferIn(baseToken, amount);

        emit Repay(msg.sender, amount);
    }

    // -------------------------------------------------------------------------------------------
    // Liquidation
    // -------------------------------------------------------------------------------------------

    /**
     * @notice Repays part of an unhealthy borrower's debt in exchange for their collateral,
     *         plus the liquidation incentive.
     * @param borrower the account being liquidated
     * @param repayAmount how much of the borrower's debt the liquidator is repaying
     */
    function liquidate(address borrower, uint256 repayAmount) external whenNotPaused {
        require(repayAmount > 0, "zero amount");
        accrueInterest();

        require(!isHealthy(borrower), "borrower is healthy");

        uint256 owed = borrowBalanceOf(borrower);
        if (repayAmount > owed) repayAmount = owed;

        // Collateral is priced in base terms, so the seized amount is the repaid base value plus the
        // incentive, converted into collateral units at the oracle price.
        uint256 price = getPrice();
        uint256 available = collateralBalance[borrower];
        uint256 collateralValue = (available * price) / FACTOR;
        uint256 seizeAmount;
        // Both sides unrounded, so the branch test and the seize math cannot disagree by one wei.
        if (available * price < owed * liquidationIncentive) {
            // The collateral cannot pay the debt plus the incentive, so the position is closed in full
            // whatever was requested. A partial close here would leave dust that dodges the write-off
            // below. The liquidator pays the whole debt while the collateral still covers it, and
            // only when it does not is the incentive taken out of the uncovered remainder.
            seizeAmount = available;
            uint256 fullRepay = collateralValue >= owed
                ? owed
                : (collateralValue * FACTOR + liquidationIncentive - 1) / liquidationIncentive;
            // Never charge more than the liquidator asked for. It must opt into the full close.
            require(repayAmount >= fullRepay, "underwater, close in full");
            repayAmount = fullRepay;
        } else {
            seizeAmount = (repayAmount * liquidationIncentive) / price;
        }

        uint256 principal = repayAmount == owed ? borrowPrincipal[borrower] : _principalForBorrow(repayAmount);
        borrowPrincipal[borrower] -= principal;
        totalBorrowPrincipal -= principal;

        collateralBalance[borrower] -= seizeAmount;
        totalCollateral -= seizeAmount;

        // With no collateral left, the remainder can never be collected. Leaving it in the borrow
        // total would keep paying suppliers interest on it, so it is written off and recorded.
        if (collateralBalance[borrower] == 0 && borrowPrincipal[borrower] > 0) {
            uint256 writtenOff = borrowBalanceOf(borrower);
            totalBorrowPrincipal -= borrowPrincipal[borrower];
            borrowPrincipal[borrower] = 0;
            badDebt += writtenOff;
            emit BadDebtWrittenOff(borrower, writtenOff);
        }

        _transferIn(baseToken, repayAmount);
        _transferOut(collateralToken, seizeAmount);

        emit Liquidate(msg.sender, borrower, repayAmount, seizeAmount);
    }

    // -------------------------------------------------------------------------------------------
    // Views
    // -------------------------------------------------------------------------------------------

    function borrowBalanceOf(address account) public view returns (uint256) {
        return presentValueBorrow(borrowPrincipal[account]);
    }

    function supplyBalanceOf(address account) public view returns (uint256) {
        return presentValueSupply(supplyPrincipal[account]);
    }

    function presentValueBorrow(uint256 principal) public view returns (uint256) {
        return (principal * baseBorrowIndex) / FACTOR;
    }

    function presentValueSupply(uint256 principal) public view returns (uint256) {
        return (principal * baseSupplyIndex) / FACTOR;
    }

    /// @notice Fraction of supplied base currently borrowed, 1e18 scaled.
    /// @dev Multiplication is applied before the division so the 1e18 scale survives; the
    ///      intermediate cannot realistically overflow at supported market sizes.
    function utilization() public view returns (uint256) {
        uint256 supplied = presentValueSupply(totalSupplyPrincipal);
        if (supplied == 0) return 0;
        return (presentValueBorrow(totalBorrowPrincipal) * FACTOR) / supplied;
    }

    /// @notice True when the account's borrowing power covers its debt.
    function isHealthy(address account) public view returns (bool) {
        uint256 debt = borrowBalanceOf(account);
        if (debt == 0) return true;

        uint256 collateralValue = (collateralBalance[account] * getPrice()) / FACTOR;
        uint256 borrowingPower = (collateralValue * collateralFactor) / FACTOR;

        return borrowingPower >= debt;
    }

    /// @notice Collateral price in base-asset terms, 1e18 scaled.
    function getPrice() public view returns (uint256) {
        (, int256 answer,, uint256 updatedAt,) = oracle.latestRoundData();
        require(answer > 0, "invalid price");
        require(updatedAt <= block.timestamp && block.timestamp - updatedAt <= maxPriceAge(), "stale price");
        // safe because answer is checked positive above
        // forge-lint: disable-next-line(unsafe-typecast)
        return uint256(answer);
    }

    /// @notice Oldest oracle answer the market accepts, in seconds.
    function maxPriceAge() public view returns (uint256) {
        return _maxPriceAge == 0 ? DEFAULT_MAX_PRICE_AGE : _maxPriceAge;
    }

    // -------------------------------------------------------------------------------------------
    // Internal accounting helpers
    // -------------------------------------------------------------------------------------------

    function _principalForBorrow(uint256 amount) internal view returns (uint256) {
        return (amount * FACTOR) / baseBorrowIndex;
    }

    function _principalForSupply(uint256 amount) internal view returns (uint256) {
        return (amount * FACTOR) / baseSupplyIndex;
    }

    /// @notice Rounds against the caller. Used where principal leaves the caller or debt is created.
    function _principalForBorrowRoundUp(uint256 amount) internal view returns (uint256) {
        return (amount * FACTOR + baseBorrowIndex - 1) / baseBorrowIndex;
    }

    /// @notice Rounds against the caller. Used where principal leaves the caller or debt is created.
    function _principalForSupplyRoundUp(uint256 amount) internal view returns (uint256) {
        return (amount * FACTOR + baseSupplyIndex - 1) / baseSupplyIndex;
    }

    /// @notice Pulls tokens from the caller and rejects a false return value as well as a revert.
    function _transferIn(IERC20 token, uint256 amount) internal {
        require(token.transferFrom(msg.sender, address(this), amount), "transfer failed");
    }

    /// @notice Pushes tokens to the caller and rejects a false return value as well as a revert.
    function _transferOut(IERC20 token, uint256 amount) internal {
        require(token.transfer(msg.sender, amount), "transfer failed");
    }

    // -------------------------------------------------------------------------------------------
    // Administration
    // -------------------------------------------------------------------------------------------

    function setOracle(address newOracle) external onlyAdmin {
        require(newOracle != address(0), "zero oracle");
        require(IPriceOracle(newOracle).decimals() == 18, "oracle decimals");
        oracle = IPriceOracle(newOracle);
        emit OracleUpdated(newOracle);
    }

    function setParameters(uint256 collateralFactor_, uint256 liquidationIncentive_, uint256 borrowRatePerSecond_)
        external
        onlyAdmin
    {
        require(collateralFactor_ <= FACTOR, "cf too high");
        require(liquidationIncentive_ >= FACTOR, "incentive below par");
        // A position at the borrow limit must still be able to pay the incentive out of its own
        // collateral, or a borrower can liquidate itself at a profit against the suppliers.
        require(collateralFactor_ * liquidationIncentive_ <= FACTOR * FACTOR, "cf times incentive above par");

        accrueInterest();

        collateralFactor = collateralFactor_;
        liquidationIncentive = liquidationIncentive_;
        borrowRatePerSecond = borrowRatePerSecond_;

        emit ParametersUpdated(collateralFactor_, liquidationIncentive_, borrowRatePerSecond_);
    }

    function setMaxPriceAge(uint256 maxPriceAge_) external onlyAdmin {
        require(maxPriceAge_ > 0, "zero max age");
        _maxPriceAge = maxPriceAge_;
        emit MaxPriceAgeUpdated(maxPriceAge_);
    }

    function setPaused(bool paused_) external onlyGuardian {
        // The guardian stops the market. Only the admin restarts it.
        if (!paused_) require(msg.sender == admin, "not admin");
        paused = paused_;
        emit PausedSet(paused_);
    }

    function setPauseGuardian(address newGuardian) external onlyAdmin {
        pauseGuardian = newGuardian;
        emit PauseGuardianUpdated(newGuardian);
    }

    // Two steps, so a wrong address cannot take the market with it. The nominee must prove it can sign.
    function setAdmin(address newAdmin) external onlyAdmin {
        require(newAdmin != address(0), "zero admin");
        pendingAdmin = newAdmin;
        emit AdminTransferStarted(newAdmin);
    }

    function acceptAdmin() external {
        require(msg.sender == pendingAdmin, "not pending admin");
        admin = pendingAdmin;
        pendingAdmin = address(0);
        emit AdminTransferred(admin);
    }
}
