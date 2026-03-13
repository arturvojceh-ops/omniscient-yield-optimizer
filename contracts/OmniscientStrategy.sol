// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts/proxy/utils/UUPSUpgradeable.sol";

import "./interfaces/IStrategy.sol";
import "./interfaces/IVault.sol";
import "./libraries/MathLib.sol";
import "./libraries/StrategyLib.sol";

/**
 * @title OmniscientStrategy
 * @notice Advanced yield strategy with multiple DeFi protocol integration
 * @dev Implements gas-efficient yield optimization across Aave, Compound, Uniswap
 * @author Omniscient Yield Optimizer Team
 */
contract OmniscientStrategy is 
    IStrategy, 
    ReentrancyGuard, 
    Ownable,
    Initializable,
    UUPSUpgradeable 
{
    using SafeERC20 for IERC20;
    using MathLib for uint256;
    using StrategyLib for uint256;

    // State variables
    IVault public vault;
    IERC20 public asset;
    IERC20 public rewardToken;
    
    // Protocol integrations
    address public aavePool;
    address public compoundComptroller;
    address public uniswapRouter;
    address public chainlinkPriceFeed;
    
    // Strategy parameters
    uint256 public totalAllocated;
    uint256 public totalYield;
    uint256 public lastYieldCollection;
    uint256 public performanceThreshold;
    uint256 public rebalanceThreshold;
    
    // Allocation tracking
    mapping(string => uint256) public protocolAllocations;
    mapping(string => uint256) public protocolYields;
    string[] public supportedProtocols;
    
    // Risk management
    uint256 public maxAllocationPerProtocol;
    uint256 public emergencyThreshold;
    bool public emergencyMode;
    
    // Gas optimization
    uint256 public batchRebalanceSize;
    uint256 public lastRebalanceTime;
    mapping(string => uint256) public pendingRebalances;
    
    // Events
    event StrategyInitialized(address indexed vault, address indexed asset);
    event DepositToProtocol(string indexed protocol, uint256 amount);
    event WithdrawalFromProtocol(string indexed protocol, uint256 amount);
    event YieldCollected(string indexed protocol, uint256 amount);
    event RebalanceExecuted(string[] protocols, uint256[] amounts);
    event EmergencyModeActivated(uint256 totalAmount);
    event EmergencyModeDeactivated();
    event PerformanceThresholdUpdated(uint256 oldThreshold, uint256 newThreshold);

    // Errors
    error InvalidProtocol();
    error InsufficientBalance();
    error ExceedsMaxAllocation();
    error EmergencyModeActive();
    error InvalidAmount();
    error Unauthorized();
    error ProtocolNotSupported();

    /**
     * @notice Initializes the strategy
     * @param _vault Vault contract address
     * @param _asset Underlying asset
     * @param _aavePool Aave pool address
     * @param _compoundComptroller Compound comptroller
     * @param _uniswapRouter Uniswap router
     * @param _priceFeed Chainlink price feed
     */
    function initialize(
        address _vault,
        address _asset,
        address _rewardToken,
        address _aavePool,
        address _compoundComptroller,
        address _uniswapRouter,
        address _priceFeed
    ) external initializer {
        __Ownable_init(msg.sender);
        __ReentrancyGuard_init();
        __UUPSUpgradeable_init();
        
        if (_vault == address(0) || _asset == address(0)) revert InvalidAmount();
        
        vault = IVault(_vault);
        asset = IERC20(_asset);
        rewardToken = IERC20(_rewardToken);
        aavePool = _aavePool;
        compoundComptroller = _compoundComptroller;
        uniswapRouter = _uniswapRouter;
        chainlinkPriceFeed = _priceFeed;
        
        // Initialize supported protocols
        supportedProtocols.push("aave");
        supportedProtocols.push("compound");
        supportedProtocols.push("uniswap");
        
        // Set default parameters
        maxAllocationPerProtocol = 5000; // 50%
        performanceThreshold = 100; // 1%
        rebalanceThreshold = 500; // 5%
        emergencyThreshold = 1000; // 10%
        batchRebalanceSize = 10;
        lastYieldCollection = block.timestamp;
        
        emit StrategyInitialized(_vault, _asset);
    }

    /**
     * @notice Deposits assets to strategy
     * @param _amount Amount to deposit
     */
    function deposit(uint256 _amount) external override nonReentrant {
        if (msg.sender != address(vault)) revert Unauthorized();
        if (_amount == 0) revert InvalidAmount();
        if (emergencyMode) revert EmergencyModeActive();
        
        // Transfer assets from vault
        asset.safeTransferFrom(address(vault), address(this), _amount);
        
        // Allocate to protocols based on optimization
        _allocateToProtocols(_amount);
        
        totalAllocated += _amount;
    }

    /**
     * @notice Withdraws assets from strategy
     * @param _amount Amount to withdraw
     */
    function withdraw(uint256 _amount) external override nonReentrant {
        if (msg.sender != address(vault)) revert Unauthorized();
        if (_amount == 0) revert InvalidAmount();
        if (_amount > totalAllocated) revert InsufficientBalance();
        
        // Withdraw from protocols
        _withdrawFromProtocols(_amount);
        
        // Transfer assets to vault
        asset.safeTransfer(address(vault), _amount);
        
        totalAllocated -= _amount;
    }

    /**
     * @notice Collects yield from all protocols
     * @return totalYieldCollected Total yield collected
     */
    function collectYield() external override nonReentrant returns (uint256 totalYieldCollected) {
        if (block.timestamp < lastYieldCollection + 1 hours) return 0;
        
        for (uint256 i = 0; i < supportedProtocols.length; i++) {
            string memory protocol = supportedProtocols[i];
            uint256 protocolYield = _collectProtocolYield(protocol);
            
            if (protocolYield > 0) {
                protocolYields[protocol] += protocolYield;
                totalYield += protocolYield;
                totalYieldCollected += protocolYield;
                
                emit YieldCollected(protocol, protocolYield);
            }
        }
        
        lastYieldCollection = block.timestamp;
    }

    /**
     * @notice Reinvests yield back into protocols
     * @param _amount Amount to reinvest
     */
    function reinvest(uint256 _amount) external override nonReentrant {
        if (msg.sender != address(vault)) revert Unauthorized();
        if (_amount == 0) revert InvalidAmount();
        if (emergencyMode) revert EmergencyModeActive();
        
        // Reinvest based on optimal allocation
        _allocateToProtocols(_amount);
    }

    /**
     * @notice Gets strategy balance
     * @return balance Total balance in strategy
     */
    function getBalance() external view override returns (uint256 balance) {
        balance = totalAllocated;
        
        // Add pending yield
        for (uint256 i = 0; i < supportedProtocols.length; i++) {
            balance += _getProtocolBalance(supportedProtocols[i]);
        }
    }

    /**
     * @notice Gets strategy performance metrics
     * @return totalAPR Total APR across all protocols
     * @return riskScore Risk score (0-1000)
     * @return efficiency Efficiency score (0-1000)
     */
    function getPerformanceMetrics() external view returns (
        uint256 totalAPR,
        uint256 riskScore,
        uint256 efficiency
    ) {
        uint256 totalProtocolYield = 0;
        uint256 totalRisk = 0;
        
        for (uint256 i = 0; i < supportedProtocols.length; i++) {
            string memory protocol = supportedProtocols[i];
            uint256 protocolBalance = _getProtocolBalance(protocol);
            uint256 protocolYield = _calculateProtocolYield(protocol, protocolBalance);
            
            totalProtocolYield += protocolYield;
            totalRisk += _getProtocolRisk(protocol);
        }
        
        // Calculate total APR
        if (totalAllocated > 0) {
            uint256 timeDiff = block.timestamp - lastYieldCollection;
            if (timeDiff > 0) {
                uint256 yearlyYield = (totalProtocolYield * 365 days) / timeDiff;
                totalAPR = (yearlyYield * 10000) / totalAllocated;
            }
        }
        
        // Calculate risk score (weighted by allocation)
        riskScore = totalRisk / supportedProtocols.length;
        
        // Calculate efficiency (yield / risk ratio)
        efficiency = totalAPR > 0 ? (totalAPR * 1000) / (riskScore + 1) : 0;
    }

    /**
     * @notice Executes rebalancing across protocols
     */
    function rebalance() external nonReentrant onlyOwner {
        if (emergencyMode) revert EmergencyModeActive();
        
        (uint256[] memory optimalAllocations, string[] memory protocols) = _calculateOptimalAllocation();
        
        // Execute rebalancing in batches for gas efficiency
        for (uint256 i = 0; i < protocols.length; i += batchRebalanceSize) {
            uint256 end = i + batchRebalanceSize > protocols.length ? 
                protocols.length : i + batchRebalanceSize;
            
            _executeBatchRebalance(protocols, optimalAllocations, i, end);
        }
        
        lastRebalanceTime = block.timestamp;
    }

    /**
     * @notice Activates emergency mode
     */
    function activateEmergencyMode() external onlyOwner {
        if (emergencyMode) return;
        
        emergencyMode = true;
        
        // Withdraw all assets from protocols
        _emergencyWithdrawAll();
        
        emit EmergencyModeActivated(totalAllocated);
    }

    /**
     * @notice Deactivates emergency mode
     */
    function deactivateEmergencyMode() external onlyOwner {
        if (!emergencyMode) return;
        
        emergencyMode = false;
        
        emit EmergencyModeDeactivated();
    }

    /**
     * @notice Updates performance threshold
     * @param _newThreshold New performance threshold
     */
    function updatePerformanceThreshold(uint256 _newThreshold) external onlyOwner {
        uint256 oldThreshold = performanceThreshold;
        performanceThreshold = _newThreshold;
        
        emit PerformanceThresholdUpdated(oldThreshold, _newThreshold);
    }

    /**
     * @notice Allocates assets to protocols based on optimization
     * @param _amount Amount to allocate
     */
    function _allocateToProtocols(uint256 _amount) internal {
        (uint256[] memory allocations, string[] memory protocols) = _calculateOptimalAllocation();
        
        for (uint256 i = 0; i < protocols.length; i++) {
            uint256 allocationAmount = (_amount * allocations[i]) / 10000;
            
            if (allocationAmount > 0) {
                _depositToProtocol(protocols[i], allocationAmount);
                protocolAllocations[protocols[i]] += allocationAmount;
            }
        }
    }

    /**
     * @notice Withdraws assets from protocols
     * @param _amount Amount to withdraw
     */
    function _withdrawFromProtocols(uint256 _amount) internal {
        // Withdraw proportionally from all protocols
        for (uint256 i = 0; i < supportedProtocols.length; i++) {
            string memory protocol = supportedProtocols[i];
            uint256 protocolAllocation = protocolAllocations[protocol];
            
            if (protocolAllocation > 0) {
                uint256 withdrawalAmount = (_amount * protocolAllocation) / totalAllocated;
                
                if (withdrawalAmount > 0) {
                    _withdrawFromProtocol(protocol, withdrawalAmount);
                    protocolAllocations[protocol] -= withdrawalAmount;
                }
            }
        }
    }

    /**
     * @notice Deposits to specific protocol
     * @param _protocol Protocol name
     * @param _amount Amount to deposit
     */
    function _depositToProtocol(string memory _protocol, uint256 _amount) internal {
        if (keccak256(bytes(_protocol)) == keccak256(bytes("aave"))) {
            _depositToAave(_amount);
        } else if (keccak256(bytes(_protocol)) == keccak256(bytes("compound"))) {
            _depositToCompound(_amount);
        } else if (keccak256(bytes(_protocol)) == keccak256(bytes("uniswap"))) {
            _depositToUniswap(_amount);
        } else {
            revert InvalidProtocol();
        }
        
        emit DepositToProtocol(_protocol, _amount);
    }

    /**
     * @notice Withdraws from specific protocol
     * @param _protocol Protocol name
     * @param _amount Amount to withdraw
     */
    function _withdrawFromProtocol(string memory _protocol, uint256 _amount) internal {
        if (keccak256(bytes(_protocol)) == keccak256(bytes("aave"))) {
            _withdrawFromAave(_amount);
        } else if (keccak256(bytes(_protocol)) == keccak256(bytes("compound"))) {
            _withdrawFromCompound(_amount);
        } else if (keccak256(bytes(_protocol)) == keccak256(bytes("uniswap"))) {
            _withdrawFromUniswap(_amount);
        } else {
            revert InvalidProtocol();
        }
        
        emit WithdrawalFromProtocol(_protocol, _amount);
    }

    /**
     * @notice Deposits to Aave protocol
     * @param _amount Amount to deposit
     */
    function _depositToAave(uint256 _amount) internal {
        // Approve Aave pool
        asset.safeApprove(aavePool, _amount);
        
        // Deposit to Aave (simplified implementation)
        // In production, use actual Aave pool interface
        // IAavePool(aavePool).deposit(address(asset), _amount, address(this), 0);
    }

    /**
     * @notice Withdraws from Aave protocol
     * @param _amount Amount to withdraw
     */
    function _withdrawFromAave(uint256 _amount) internal {
        // Withdraw from Aave (simplified implementation)
        // In production, use actual Aave pool interface
        // IAavePool(aavePool).withdraw(address(asset), _amount, address(this));
    }

    /**
     * @notice Deposits to Compound protocol
     * @param _amount Amount to deposit
     */
    function _depositToCompound(uint256 _amount) internal {
        // Approve Compound
        asset.safeApprove(compoundComptroller, _amount);
        
        // Supply to Compound (simplified implementation)
        // In production, use actual Compound interface
        // IComptroller(compoundComptroller).enterMarkets([address(asset)]);
        // ICErc20(address(asset)).mint(_amount);
    }

    /**
     * @notice Withdraws from Compound protocol
     * @param _amount Amount to withdraw
     */
    function _withdrawFromCompound(uint256 _amount) internal {
        // Redeem from Compound (simplified implementation)
        // In production, use actual Compound interface
        // ICErc20(address(asset)).redeemUnderlying(_amount);
    }

    /**
     * @notice Deposits to Uniswap V3
     * @param _amount Amount to deposit
     */
    function _depositToUniswap(uint256 _amount) internal {
        // Create liquidity position (simplified implementation)
        // In production, use actual Uniswap V3 interface
        // IUniswapV3Router(uniswapRouter).exactInputSingle(...);
    }

    /**
     * @notice Withdraws from Uniswap V3
     * @param _amount Amount to withdraw
     */
    function _withdrawFromUniswap(uint256 _amount) internal {
        // Remove liquidity position (simplified implementation)
        // In production, use actual Uniswap V3 interface
        // IUniswapV3Router(uniswapRouter).exactOutputSingle(...);
    }

    /**
     * @notice Calculates optimal allocation across protocols
     * @return allocations Optimal allocations (basis points)
     * @return protocols Protocol names
     */
    function _calculateOptimalAllocation() internal view returns (uint256[] memory allocations, string[] memory protocols) {
        allocations = new uint256[](supportedProtocols.length);
        protocols = new string[](supportedProtocols.length);
        
        // Simplified allocation logic - in production, use sophisticated optimization
        uint256 totalAllocation = 0;
        
        for (uint256 i = 0; i < supportedProtocols.length; i++) {
            protocols[i] = supportedProtocols[i];
            
            // Calculate allocation based on current APR and risk
            uint256 protocolAPR = _getProtocolAPR(supportedProtocols[i]);
            uint256 protocolRisk = _getProtocolRisk(supportedProtocols[i]);
            
            // Risk-adjusted allocation
            uint256 riskAdjustedAPR = protocolAPR * (1000 - protocolRisk) / 1000;
            allocations[i] = riskAdjustedAPR;
            totalAllocation += riskAdjustedAPR;
        }
        
        // Normalize to 10000 basis points
        if (totalAllocation > 0) {
            for (uint256 i = 0; i < allocations.length; i++) {
                allocations[i] = (allocations[i] * 10000) / totalAllocation;
            }
        }
    }

    /**
     * @notice Executes batch rebalancing
     * @param _protocols Protocol names
     * @param _allocations Target allocations
     * @param _start Start index
     * @param _end End index
     */
    function _executeBatchRebalance(
        string[] memory _protocols,
        uint256[] memory _allocations,
        uint256 _start,
        uint256 _end
    ) internal {
        for (uint256 i = _start; i < _end; i++) {
            uint256 currentAllocation = protocolAllocations[_protocols[i]];
            uint256 targetAllocation = (totalAllocated * _allocations[i]) / 10000;
            
            if (targetAllocation > currentAllocation) {
                uint256 depositAmount = targetAllocation - currentAllocation;
                _depositToProtocol(_protocols[i], depositAmount);
                protocolAllocations[_protocols[i]] = targetAllocation;
            } else if (targetAllocation < currentAllocation) {
                uint256 withdrawalAmount = currentAllocation - targetAllocation;
                _withdrawFromProtocol(_protocols[i], withdrawalAmount);
                protocolAllocations[_protocols[i]] = targetAllocation;
            }
        }
    }

    /**
     * @notice Emergency withdrawal from all protocols
     */
    function _emergencyWithdrawAll() internal {
        for (uint256 i = 0; i < supportedProtocols.length; i++) {
            string memory protocol = supportedProtocols[i];
            uint256 allocation = protocolAllocations[protocol];
            
            if (allocation > 0) {
                _withdrawFromProtocol(protocol, allocation);
                protocolAllocations[protocol] = 0;
            }
        }
        
        totalAllocated = 0;
    }

    /**
     * @notice Gets protocol balance
     * @param _protocol Protocol name
     * @return balance Protocol balance
     */
    function _getProtocolBalance(string memory _protocol) internal view returns (uint256 balance) {
        // Simplified implementation - in production, query actual protocol balances
        balance = protocolAllocations[_protocol];
    }

    /**
     * @notice Gets protocol APR
     * @param _protocol Protocol name
     * @return apr Protocol APR
     */
    function _getProtocolAPR(string memory _protocol) internal view returns (uint256 apr) {
        // Simplified implementation - in production, query actual protocol APRs
        if (keccak256(bytes(_protocol)) == keccak256(bytes("aave"))) {
            apr = 500; // 5%
        } else if (keccak256(bytes(_protocol)) == keccak256(bytes("compound"))) {
            apr = 450; // 4.5%
        } else if (keccak256(bytes(_protocol)) == keccak256(bytes("uniswap"))) {
            apr = 600; // 6%
        } else {
            apr = 0;
        }
    }

    /**
     * @notice Gets protocol risk score
     * @param _protocol Protocol name
     * @return risk Risk score (0-1000)
     */
    function _getProtocolRisk(string memory _protocol) internal view returns (uint256 risk) {
        // Simplified risk assessment
        if (keccak256(bytes(_protocol)) == keccak256(bytes("aave"))) {
            risk = 200; // Low risk
        } else if (keccak256(bytes(_protocol)) == keccak256(bytes("compound"))) {
            risk = 250; // Low-medium risk
        } else if (keccak256(bytes(_protocol)) == keccak256(bytes("uniswap"))) {
            risk = 400; // Medium risk
        } else {
            risk = 1000; // High risk
        }
    }

    /**
     * @notice Calculates protocol yield
     * @param _protocol Protocol name
     * @param _balance Protocol balance
     * @return yield Protocol yield
     */
    function _calculateProtocolYield(string memory _protocol, uint256 _balance) internal view returns (uint256 yield) {
        uint256 apr = _getProtocolAPR(_protocol);
        uint256 timeDiff = block.timestamp - lastYieldCollection;
        
        if (timeDiff > 0) {
            yield = (_balance * apr * timeDiff) / (10000 * 365 days);
        }
    }

    /**
     * @notice Collects yield from specific protocol
     * @param _protocol Protocol name
     * @return protocolYield Yield collected
     */
    function _collectProtocolYield(string memory _protocol) internal returns (uint256 protocolYield) {
        uint256 balance = _getProtocolBalance(_protocol);
        protocolYield = _calculateProtocolYield(_protocol, balance);
        
        // In production, implement actual yield collection logic
        // This would involve claiming rewards, harvesting, etc.
    }

    /**
     * @notice Authorizes upgrade
     * @param newImplementation New implementation address
     */
    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}
}
