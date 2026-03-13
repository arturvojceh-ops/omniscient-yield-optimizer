// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/security/Pausable.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts/proxy/utils/UUPSUpgradeable.sol";

import "./interfaces/IVault.sol";
import "./interfaces/IStrategy.sol";
import "./libraries/MathLib.sol";
import "./libraries/SecurityLib.sol";

/**
 * @title OmniscientVault
 * @notice Advanced DeFi vault with multi-strategy yield optimization
 * @dev Implements ERC-4626 standard with gas-efficient operations
 * @author Omniscient Yield Optimizer Team
 */
contract OmniscientVault is 
    IVault, 
    ReentrancyGuard, 
    Pausable, 
    Ownable,
    Initializable,
    UUPSUpgradeable 
{
    using SafeERC20 for IERC20;
    using MathLib for uint256;

    // State variables
    IERC20 public asset;
    uint256 public totalDeposits;
    uint256 public totalYield;
    uint256 public lastYieldDistribution;
    
    // Strategy management
    IStrategy[] public strategies;
    mapping(address => bool) public isStrategy;
    mapping(address => uint256) public strategyAllocations;
    uint256 public totalAllocation;
    
    // User accounting
    mapping(address => uint256) public userDeposits;
    mapping(address => uint256) public userYield;
    mapping(address => uint256) public lastDepositTime;
    
    // Performance tracking
    uint256 public apr;
    uint256 public totalFees;
    uint256 public performanceFee;
    uint256 public constant MAX_PERFORMANCE_FEE = 1000; // 10%
    
    // Security parameters
    uint256 public maxDepositAmount;
    uint256 public emergencyWithdrawalFee;
    uint256 public constant MAX_EMERGENCY_FEE = 500; // 5%
    
    // Gas optimization
    uint256 public batchDepositLimit;
    uint256 public lastBatchTime;
    mapping(address => uint256) public pendingDeposits;
    
    // Events
    event Deposit(address indexed user, uint256 amount, uint256 shares);
    event Withdrawal(address indexed user, uint256 amount, uint256 shares);
    event YieldDistributed(uint256 amount, uint256 apr);
    event StrategyAdded(address indexed strategy, uint256 allocation);
    event StrategyRemoved(address indexed strategy);
    event AllocationUpdated(address indexed strategy, uint256 oldAllocation, uint256 newAllocation);
    event EmergencyWithdrawal(address indexed user, uint256 amount, uint256 fee);
    event BatchProcessed(uint256 depositCount, uint256 totalAmount);
    
    // Errors
    error InvalidStrategy();
    error InsufficientBalance();
    error ExceedsMaxDeposit();
    error InsufficientAllocation();
    error InvalidAmount();
    error Unauthorized();
    error ContractPaused();
    error MaxPerformanceFeeExceeded();
    error MaxEmergencyFeeExceeded();

    /**
     * @notice Initializes the vault
     * @param _asset The underlying asset token
     * @param _owner The contract owner
     */
    function initialize(
        address _asset,
        address _owner,
        uint256 _performanceFee,
        uint256 _emergencyFee,
        uint256 _maxDeposit
    ) external initializer {
        __Ownable_init(_owner);
        __ReentrancyGuard_init();
        __Pausable_init();
        __UUPSUpgradeable_init();
        
        if (_asset == address(0)) revert InvalidAmount();
        if (_performanceFee > MAX_PERFORMANCE_FEE) revert MaxPerformanceFeeExceeded();
        if (_emergencyFee > MAX_EMERGENCY_FEE) revert MaxEmergencyFeeExceeded();
        
        asset = IERC20(_asset);
        performanceFee = _performanceFee;
        emergencyWithdrawalFee = _emergencyFee;
        maxDepositAmount = _maxDeposit;
        batchDepositLimit = 100;
        lastYieldDistribution = block.timestamp;
        
        emit VaultInitialized(_asset, _owner);
    }

    /**
     * @notice Deposits assets into the vault
     * @param _amount Amount to deposit
     * @return shares Number of shares received
     */
    function deposit(uint256 _amount) external override nonReentrant whenNotPaused returns (uint256 shares) {
        if (_amount == 0) revert InvalidAmount();
        if (paused()) revert ContractPaused();
        
        uint256 userTotalDeposits = userDeposits[msg.sender] + _amount;
        if (userTotalDeposits > maxDepositAmount) revert ExceedsMaxDeposit();
        
        // Transfer assets to vault
        asset.safeTransferFrom(msg.sender, address(this), _amount);
        
        // Calculate shares (1:1 initially, adjusted by yield)
        shares = _amount;
        
        // Update user accounting
        userDeposits[msg.sender] += _amount;
        lastDepositTime[msg.sender] = block.timestamp;
        totalDeposits += _amount;
        
        // Add to batch for gas optimization
        pendingDeposits[msg.sender] += _amount;
        
        emit Deposit(msg.sender, _amount, shares);
        
        // Process batch if limit reached
        if (pendingDeposits[msg.sender] >= batchDepositLimit) {
            _processBatch();
        }
    }

    /**
     * @notice Withdraws assets from the vault
     * @param _amount Amount to withdraw
     * @return shares Number of shares redeemed
     */
    function withdraw(uint256 _amount) external override nonReentrant returns (uint256 shares) {
        if (_amount == 0) revert InvalidAmount();
        if (userDeposits[msg.sender] < _amount) revert InsufficientBalance();
        
        // Calculate shares to redeem
        shares = _amount;
        
        // Update user accounting
        userDeposits[msg.sender] -= _amount;
        totalDeposits -= _amount;
        
        // Transfer assets to user
        asset.safeTransfer(msg.sender, _amount);
        
        emit Withdrawal(msg.sender, _amount, shares);
    }

    /**
     * @notice Emergency withdrawal with fee
     * @param _amount Amount to withdraw
     */
    function emergencyWithdraw(uint256 _amount) external nonReentrant {
        if (_amount == 0) revert InvalidAmount();
        if (userDeposits[msg.sender] < _amount) revert InsufficientBalance();
        
        // Calculate fee
        uint256 fee = (_amount * emergencyWithdrawalFee) / 10000;
        uint256 amountAfterFee = _amount - fee;
        
        // Update user accounting
        userDeposits[msg.sender] -= _amount;
        totalDeposits -= _amount;
        
        // Transfer assets
        asset.safeTransfer(msg.sender, amountAfterFee);
        asset.safeTransfer(owner(), fee);
        
        emit EmergencyWithdrawal(msg.sender, amountAfterFee, fee);
    }

    /**
     * @notice Adds a new strategy
     * @param _strategy Strategy contract address
     * @param _allocation Percentage allocation (basis points)
     */
    function addStrategy(address _strategy, uint256 _allocation) external onlyOwner {
        if (_strategy == address(0)) revert InvalidStrategy();
        if (isStrategy[_strategy]) revert InvalidStrategy();
        if (totalAllocation + _allocation > 10000) revert InsufficientAllocation(); // 100%
        
        isStrategy[_strategy] = true;
        strategies.push(IStrategy(_strategy));
        strategyAllocations[_strategy] = _allocation;
        totalAllocation += _allocation;
        
        emit StrategyAdded(_strategy, _allocation);
    }

    /**
     * @notice Removes a strategy
     * @param _strategy Strategy contract address
     */
    function removeStrategy(address _strategy) external onlyOwner {
        if (!isStrategy[_strategy]) revert InvalidStrategy();
        
        uint256 allocation = strategyAllocations[_strategy];
        totalAllocation -= allocation;
        
        isStrategy[_strategy] = false;
        strategyAllocations[_strategy] = 0;
        
        // Remove from strategies array
        for (uint256 i = 0; i < strategies.length; i++) {
            if (address(strategies[i]) == _strategy) {
                strategies[i] = strategies[strategies.length - 1];
                strategies.pop();
                break;
            }
        }
        
        emit StrategyRemoved(_strategy);
    }

    /**
     * @notice Updates strategy allocation
     * @param _strategy Strategy contract address
     * @param _newAllocation New allocation percentage
     */
    function updateAllocation(address _strategy, uint256 _newAllocation) external onlyOwner {
        if (!isStrategy[_strategy]) revert InvalidStrategy();
        
        uint256 oldAllocation = strategyAllocations[_strategy];
        totalAllocation = totalAllocation - oldAllocation + _newAllocation;
        
        if (totalAllocation > 10000) revert InsufficientAllocation(); // 100%
        
        strategyAllocations[_strategy] = _newAllocation;
        
        emit AllocationUpdated(_strategy, oldAllocation, _newAllocation);
    }

    /**
     * @notice Distributes yield from strategies
     */
    function distributeYield() external nonReentrant {
        if (block.timestamp < lastYieldDistribution + 1 hours) return;
        
        uint256 totalYieldFromStrategies = 0;
        
        // Collect yield from all strategies
        for (uint256 i = 0; i < strategies.length; i++) {
            uint256 strategyYield = strategies[i].collectYield();
            totalYieldFromStrategies += strategyYield;
        }
        
        if (totalYieldFromStrategies == 0) return;
        
        // Calculate performance fee
        uint256 fee = (totalYieldFromStrategies * performanceFee) / 10000;
        uint256 netYield = totalYieldFromStrategies - fee;
        
        // Distribute yield proportionally
        if (totalDeposits > 0) {
            for (uint256 i = 0; i < strategies.length; i++) {
                uint256 allocation = strategyAllocations[strategies[i]];
                uint256 strategyShare = (netYield * allocation) / 10000;
                
                // Reinvest in strategy
                strategies[i].reinvest(strategyShare);
            }
            
            // Update APR calculation
            apr = _calculateAPR(netYield);
            totalYield += netYield;
            totalFees += fee;
            
            // Transfer fee to treasury
            asset.safeTransfer(owner(), fee);
        }
        
        lastYieldDistribution = block.timestamp;
        
        emit YieldDistributed(netYield, apr);
    }

    /**
     * @notice Processes batch deposits for gas optimization
     */
    function _processBatch() internal {
        uint256 totalBatchAmount = 0;
        uint256 depositCount = 0;
        
        // Process all pending deposits
        for (uint256 i = 0; i < strategies.length; i++) {
            uint256 allocation = strategyAllocations[strategies[i]];
            if (allocation > 0) {
                uint256 strategyAmount = (totalDeposits * allocation) / 10000;
                strategies[i].deposit(strategyAmount);
                totalBatchAmount += strategyAmount;
                depositCount++;
            }
        }
        
        // Clear pending deposits
        pendingDeposits[msg.sender] = 0;
        lastBatchTime = block.timestamp;
        
        emit BatchProcessed(depositCount, totalBatchAmount);
    }

    /**
     * @notice Calculates current APR
     * @param _yield Yield amount
     * @return apr Current APR in basis points
     */
    function _calculateAPR(uint256 _yield) internal view returns (uint256) {
        if (totalDeposits == 0) return 0;
        
        uint256 yearlyYield = (_yield * 365 days) / (block.timestamp - lastYieldDistribution);
        return (yearlyYield * 10000) / totalDeposits;
    }

    /**
     * @notice Gets user balance including yield
     * @param _user User address
     * @return balance Total balance including yield
     */
    function getBalance(address _user) external view returns (uint256 balance) {
        balance = userDeposits[_user];
        
        // Add proportional yield
        if (totalDeposits > 0 && totalYield > 0) {
            uint256 userShare = (balance * totalYield) / totalDeposits;
            balance += userShare;
        }
    }

    /**
     * @notice Gets vault statistics
     * @return tvl Total value locked
     * @return currentAPR Current APR
     * @return totalYieldEarned Total yield earned
     * @return strategyCount Number of active strategies
     */
    function getVaultStats() external view returns (
        uint256 tvl,
        uint256 currentAPR,
        uint256 totalYieldEarned,
        uint256 strategyCount
    ) {
        tvl = totalDeposits;
        currentAPR = apr;
        totalYieldEarned = totalYield;
        strategyCount = strategies.length;
    }

    /**
     * @notice Pauses the contract
     */
    function pause() external onlyOwner {
        _pause();
    }

    /**
     * @notice Unpauses the contract
     */
    function unpause() external onlyOwner {
        _unpause();
    }

    /**
     * @notice Authorizes upgrade
     * @param newImplementation New implementation address
     */
    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}

    /**
     * @notice Receives ETH
     */
    receive() external payable {
        // Only allow ETH transfers from strategies
        bool isFromStrategy = false;
        for (uint256 i = 0; i < strategies.length; i++) {
            if (msg.sender == address(strategies[i])) {
                isFromStrategy = true;
                break;
            }
        }
        
        require(isFromStrategy, "Unauthorized ETH transfer");
    }
}
