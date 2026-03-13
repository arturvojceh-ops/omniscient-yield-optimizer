// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/ERC20Votes.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts/proxy/utils/UUPSUpgradeable.sol";

/**
 * @title OmniscientToken
 * @notice Governance and utility token for Omniscient Yield Optimizer
 * @dev Implements ERC20 with voting, permit, and upgradeable features
 * @author Omniscient Yield Optimizer Team
 */
contract OmniscientToken is 
    ERC20, 
    ERC20Permit, 
    ERC20Votes,
    Ownable,
    Initializable,
    UUPSUpgradeable 
{
    // Token metadata
    string public constant NAME = "Omniscient Token";
    string public constant SYMBOL = "OMN";
    uint8 public constant DECIMALS = 18;
    
    // Supply parameters
    uint256 public constant MAX_SUPPLY = 100_000_000 * 10**DECIMALS; // 100M tokens
    uint256 public constant INITIAL_SUPPLY = 60_000_000 * 10**DECIMALS; // 60M tokens
    
    // Vesting parameters
    mapping(address => uint256) public vestingAmount;
    mapping(address => uint256) public vestingStart;
    mapping(address => uint256) public vestingDuration;
    mapping(address => uint256) public lastClaim;
    
    // Governance parameters
    uint256 public votingDelay;
    uint256 public votingPeriod;
    uint256 public proposalThreshold;
    uint256 public quorumVotes;
    
    // Fee parameters
    uint256 public transferFee;
    uint256 public constant MAX_TRANSFER_FEE = 500; // 5%
    address public feeRecipient;
    
    // Events
    event TokensMinted(address indexed to, uint256 amount);
    event TokensBurned(address indexed from, uint256 amount);
    event VestingSet(address indexed user, uint256 amount, uint256 duration);
    event VestingClaimed(address indexed user, uint256 amount);
    event TransferFeeUpdated(uint256 oldFee, uint256 newFee);
    event FeeRecipientUpdated(address indexed oldRecipient, address indexed newRecipient);
    event GovernanceParamsUpdated(
        uint256 votingDelay,
        uint256 votingPeriod,
        uint256 proposalThreshold,
        uint256 quorumVotes
    );

    // Errors
    error MaxSupplyExceeded();
    error InsufficientVestedTokens();
    error VestingNotStarted();
    error TransferFeeExceeded();
    error InvalidAmount();
    error Unauthorized();

    /**
     * @notice Initializes the token
     * @param _owner Contract owner
     * @param _feeRecipient Fee recipient
     * @param _initialMintAmount Initial amount to mint
     */
    function initialize(
        address _owner,
        address _feeRecipient,
        uint256 _initialMintAmount
    ) external initializer {
        __ERC20_init(NAME, SYMBOL);
        __ERC20Permit_init(NAME);
        __ERC20Votes_init();
        __Ownable_init(_owner);
        __UUPSUpgradeable_init();
        
        if (_owner == address(0) || _feeRecipient == address(0)) revert InvalidAmount();
        if (_initialMintAmount > INITIAL_SUPPLY) revert MaxSupplyExceeded();
        
        feeRecipient = _feeRecipient;
        
        // Set default governance parameters
        votingDelay = 1 days;
        votingPeriod = 7 days;
        proposalThreshold = 100_000 * 10**DECIMALS; // 100K tokens
        quorumVotes = 1_000_000 * 10**DECIMALS; // 1M tokens
        
        // Mint initial supply
        if (_initialMintAmount > 0) {
            _mint(_owner, _initialMintAmount);
            emit TokensMinted(_owner, _initialMintAmount);
        }
    }

    /**
     * @notice Mints tokens to specified address
     * @param _to Recipient address
     * @param _amount Amount to mint
     */
    function mint(address _to, uint256 _amount) external onlyOwner {
        if (_to == address(0)) revert InvalidAmount();
        if (totalSupply() + _amount > MAX_SUPPLY) revert MaxSupplyExceeded();
        
        _mint(_to, _amount);
        emit TokensMinted(_to, _amount);
    }

    /**
     * @notice Burns tokens from caller
     * @param _amount Amount to burn
     */
    function burn(uint256 _amount) external {
        if (_amount == 0) revert InvalidAmount();
        if (_amount > balanceOf(msg.sender)) revert InsufficientVestedTokens();
        
        _burn(msg.sender, _amount);
        emit TokensBurned(msg.sender, _amount);
    }

    /**
     * @notice Sets vesting for user
     * @param _user User address
     * @param _amount Vesting amount
     * @param _duration Vesting duration in seconds
     */
    function setVesting(
        address _user,
        uint256 _amount,
        uint256 _duration
    ) external onlyOwner {
        if (_user == address(0)) revert InvalidAmount();
        
        vestingAmount[_user] = _amount;
        vestingStart[_user] = block.timestamp;
        vestingDuration[_user] = _duration;
        lastClaim[_user] = block.timestamp;
        
        emit VestingSet(_user, _amount, _duration);
    }

    /**
     * @notice Claims vested tokens
     * @param _amount Amount to claim
     */
    function claimVested(uint256 _amount) external {
        if (_amount == 0) revert InvalidAmount();
        
        uint256 vestedAmount = _getVestedAmount(msg.sender);
        if (vestedAmount < _amount) revert InsufficientVestedTokens();
        
        // Update last claim and reduce vesting amount
        lastClaim[msg.sender] = block.timestamp;
        vestingAmount[msg.sender] -= _amount;
        
        // Transfer claimed tokens
        _transfer(address(this), msg.sender, _amount);
        
        emit VestingClaimed(msg.sender, _amount);
    }

    /**
     * @notice Gets vested amount for user
     * @param _user User address
     * @return vestedAmount Amount of vested tokens
     */
    function getVestedAmount(address _user) external view returns (uint256 vestedAmount) {
        vestedAmount = _getVestedAmount(_user);
    }

    /**
     * @notice Updates transfer fee
     * @param _newFee New transfer fee (basis points)
     */
    function updateTransferFee(uint256 _newFee) external onlyOwner {
        if (_newFee > MAX_TRANSFER_FEE) revert TransferFeeExceeded();
        
        uint256 oldFee = transferFee;
        transferFee = _newFee;
        
        emit TransferFeeUpdated(oldFee, _newFee);
    }

    /**
     * @notice Updates fee recipient
     * @param _newRecipient New fee recipient
     */
    function updateFeeRecipient(address _newRecipient) external onlyOwner {
        if (_newRecipient == address(0)) revert InvalidAmount();
        
        address oldRecipient = feeRecipient;
        feeRecipient = _newRecipient;
        
        emit FeeRecipientUpdated(oldRecipient, _newRecipient);
    }

    /**
     * @notice Updates governance parameters
     * @param _votingDelay New voting delay
     * @param _votingPeriod New voting period
     * @param _proposalThreshold New proposal threshold
     * @param _quorumVotes New quorum votes
     */
    function updateGovernanceParams(
        uint256 _votingDelay,
        uint256 _votingPeriod,
        uint256 _proposalThreshold,
        uint256 _quorumVotes
    ) external onlyOwner {
        votingDelay = _votingDelay;
        votingPeriod = _votingPeriod;
        proposalThreshold = _proposalThreshold;
        quorumVotes = _quorumVotes;
        
        emit GovernanceParamsUpdated(_votingDelay, _votingPeriod, _proposalThreshold, _quorumVotes);
    }

    /**
     * @notice Gets token statistics
     * @return totalSupply_ Total supply
     * @return circulatingSupply Circulating supply
     * @return vestedSupply Total vested supply
     * @return lockedSupply Total locked supply
     */
    function getTokenStats() external view returns (
        uint256 totalSupply_,
        uint256 circulatingSupply,
        uint256 vestedSupply,
        uint256 lockedSupply
    ) {
        totalSupply_ = totalSupply();
        circulatingSupply = totalSupply_;
        vestedSupply = 0;
        lockedSupply = 0;
        
        // Calculate vested and locked supply (simplified)
        // In production, implement more sophisticated calculation
    }

    /**
     * @notice Override transfer to include fee
     * @param _from Sender address
     * @param _to Recipient address
     * @param _amount Transfer amount
     * @return success Transfer success
     */
    function _transfer(
        address _from,
        address _to,
        uint256 _amount
    ) internal override returns (bool success) {
        if (_amount == 0) revert InvalidAmount();
        
        uint256 fee = 0;
        
        // Apply transfer fee if not from owner
        if (_from != owner() && transferFee > 0) {
            fee = (_amount * transferFee) / 10000;
            uint256 amountAfterFee = _amount - fee;
            
            // Transfer amount after fee
            super._transfer(_from, _to, amountAfterFee);
            
            // Transfer fee to recipient
            if (fee > 0) {
                super._transfer(_from, feeRecipient, fee);
            }
        } else {
            // Normal transfer
            super._transfer(_from, _to, _amount);
        }
        
        return true;
    }

    /**
     * @notice Calculates vested amount for user
     * @param _user User address
     * @return vestedAmount Amount of vested tokens
     */
    function _getVestedAmount(address _user) internal view returns (uint256 vestedAmount) {
        if (vestingAmount[_user] == 0) return 0;
        
        uint256 startTime = vestingStart[_user];
        uint256 duration = vestingDuration[_user];
        uint256 lastClaimTime = lastClaim[_user];
        
        if (block.timestamp < startTime) return 0;
        
        uint256 elapsed = block.timestamp - startTime;
        uint256 totalVestingTime = vestingStart[_user] + duration - startTime;
        
        if (elapsed >= totalVestingTime) {
            // Fully vested
            return vestingAmount[_user];
        } else {
            // Partially vested
            uint256 vested = (vestingAmount[_user] * elapsed) / totalVestingTime;
            uint256 claimed = (vestingAmount[_user] * (lastClaimTime - startTime)) / totalVestingTime;
            return vested - claimed;
        }
    }

    /**
     * @notice Override _beforeTokenTransfer for vesting checks
     * @param _from Sender address
     * @param _to Recipient address
     * @param _amount Transfer amount
     */
    function _beforeTokenTransfer(
        address _from,
        address _to,
        uint256 _amount
    ) internal override {
        // Check vesting restrictions
        if (_from != address(0) && _from != owner()) {
            uint256 availableBalance = balanceOf(_from) - vestingAmount[_from];
            if (_amount > availableBalance) {
                revert InsufficientVestedTokens();
            }
        }
        
        super._beforeTokenTransfer(_from, _to, _amount);
    }

    /**
     * @notice Override _afterTokenTransfer for voting power
     * @param _from Sender address
     * @param _to Recipient address
     * @param _amount Transfer amount
     */
    function _afterTokenTransfer(
        address _from,
        address _to,
        uint256 _amount
    ) internal override(ERC20Votes) {
        super._afterTokenTransfer(_from, _to, _amount);
    }

    /**
     * @notice Override clocks for voting
     * @return clock Current block timestamp
     */
    function clock() public view override returns (uint48) {
        return uint48(block.timestamp);
    }

    /**
     * @notice Override CLOCK_MODE
     * @return mode Clock mode
     */
    function CLOCK_MODE() public pure override returns (string memory) {
        return "mode=timestamp";
    }

    /**
     * @notice Authorizes upgrade
     * @param newImplementation New implementation address
     */
    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}
}
