// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

interface IStakingACM {
    function hasRole(bytes32 role, address account) external view returns (bool);
}

contract WBondToken is ERC20 {
    uint256 public constant BPS = 10000;
    uint256 public immutable endOfBondingPeriod;
    uint256 public immutable maturityTimestamp;
    uint256 public immutable yield; // in BPS
    IStakingACM public stakingACM;
    address public treasuryAddress;

    // Custom errors
    error Unauthorized();
    error BondingPeriodEnded();
    error BondingPeriodActive();
    error BondNotMatured();
    error InsufficientBalance();
    error NoTokens();
    error TreasuryAlreadyWithdrawn();
    error InvalidTreasuryAddress();
    error TransferFailed();
    error ExcessRefunded();

    // Events
    event Deposited(address indexed user, uint256 amount);
    event Claimed(address indexed user, uint256 amount);
    event TreasuryWithdrawn(address indexed treasury, uint256 amount);
    event TreasuryRepaid(address indexed treasury, uint256 amount, uint256 excessRefunded);
    event TreasuryAddressUpdated(address indexed oldTreasury, address indexed newTreasury);

    modifier onlyAdmin() {
        if (!stakingACM.hasRole(0x00, msg.sender)) revert Unauthorized();
        _;
    }

    modifier onlyDuringBondingPeriod() {
        if (block.timestamp > endOfBondingPeriod) revert BondingPeriodEnded();
        _;
    }

    modifier onlyAfterMaturity() {
        if (block.timestamp < maturityTimestamp) revert BondNotMatured();
        _;
    }

    constructor(
        string memory name, 
        string memory symbol, 
        uint256 _endOfBondingPeriod, 
        uint256 _maturityTimestamp, 
        uint256 _yield, 
        address _stakingACM,
        address _treasuryAddress
    ) ERC20(name, symbol) {
        if (_endOfBondingPeriod >= _maturityTimestamp) revert BondingPeriodEnded();
        if (_treasuryAddress == address(0)) revert InvalidTreasuryAddress();
        
        endOfBondingPeriod = _endOfBondingPeriod;
        maturityTimestamp = _maturityTimestamp;
        yield = _yield;
        stakingACM = IStakingACM(_stakingACM);
        treasuryAddress = _treasuryAddress;
    }

    /**
     * @notice Deposit WCO and mint bond tokens 1:1
     * @dev Only available during bonding period
     */
    function deposit() external payable onlyDuringBondingPeriod {
        if (msg.value == 0) revert InsufficientBalance();
        
        _mint(msg.sender, msg.value);
        
        emit Deposited(msg.sender, msg.value);
    }

    /**
     * @notice Claim WCO back with yield after maturity
     * @dev Burns bond tokens and transfers WCO + yield
     */
    function claim() external onlyAfterMaturity {
        uint256 bondBalance = balanceOf(msg.sender);
        if (bondBalance == 0) revert NoTokens();
        
        uint256 yieldAmount = (bondBalance * yield) / BPS;
        uint256 totalPayout = bondBalance + yieldAmount;
        
        if (address(this).balance < totalPayout) revert InsufficientBalance();
        
        _burn(msg.sender, bondBalance);
        
        // Transfer WCO + yield
        (bool success, ) = msg.sender.call{value: totalPayout}("");
        if (!success) revert TransferFailed();
        
        emit Claimed(msg.sender, totalPayout);
    }

    /**
     * @notice Admin function to withdraw WCO to treasury
     * @dev Can only be called once by admin
     */
    function withdrawToTreasury() external onlyAdmin {
        if (address(this).balance == 0) revert InsufficientBalance();
        
        uint256 amount = address(this).balance;
        
        (bool success, ) = treasuryAddress.call{value: amount}("");
        if (!success) revert TransferFailed();
        
        emit TreasuryWithdrawn(treasuryAddress, amount);
    }

    /**
     * @notice Treasury function to repay WCO + yield before maturity
     * @dev Can be called multiple times, automatically refunds excess
     */
    function treasuryRepay() external payable onlyAdmin {
        if (msg.value == 0) revert InsufficientBalance();
        
        uint256 requiredAmount = getRequiredBalance();
        uint256 currentBalance = address(this).balance - msg.value; // Balance before this deposit
        uint256 stillNeeded = requiredAmount > currentBalance ? requiredAmount - currentBalance : 0;
        
        uint256 excessRefunded = 0;
        if (msg.value > stillNeeded && stillNeeded > 0) {
            // Refund excess
            excessRefunded = msg.value - stillNeeded;
            (bool success, ) = msg.sender.call{value: excessRefunded}("");
            if (!success) revert TransferFailed();
        } else if (stillNeeded == 0) {
            // Already fully funded, refund all
            excessRefunded = msg.value;
            (bool success, ) = msg.sender.call{value: excessRefunded}("");
            if (!success) revert TransferFailed();
        }
        
        emit TreasuryRepaid(msg.sender, msg.value, excessRefunded);
    }

    /**
     * @notice Update treasury address
     * @param _newTreasury New treasury address
     */
    function updateTreasuryAddress(address _newTreasury) external onlyAdmin {
        if (_newTreasury == address(0)) revert InvalidTreasuryAddress();
        
        address oldTreasury = treasuryAddress;
        treasuryAddress = _newTreasury;
        
        emit TreasuryAddressUpdated(oldTreasury, _newTreasury);
    }

    /**
     * @notice Get user's deposit amount
     * @param user User address
     * @return User's total deposit
     */
    function getUserDeposit(address user) external view returns (uint256) {
        return balanceOf(user);
    }

    /**
     * @notice Calculate expected payout for a user
     * @param user User address
     * @return principal and yield amounts
     */
    function getExpectedPayout(address user) external view returns (uint256 principal, uint256 yieldAmount) {
        principal = balanceOf(user);
        yieldAmount = (principal * yield) / 10000;
    }

    /**
     * @notice Calculate total required balance for all payouts
     * @return Total WCO needed to pay all bondholders
     */
    function getRequiredBalance() public view returns (uint256) {
        uint256 totalSupply = totalSupply();
        uint256 totalYield = (totalSupply * yield) / 10000;
        return totalSupply + totalYield;
    }

    /**
     * @notice Get offset counter (difference between required and actual balance)
     * @return offset Positive if contract has excess, negative if underfunded
     */
    function getOffsetCounter() external view returns (int256 offset) {
        uint256 requiredBalance = getRequiredBalance();
        uint256 actualBalance = address(this).balance;
        
        if (actualBalance >= requiredBalance) {
            offset = int256(actualBalance - requiredBalance);
        } else {
            offset = -int256(requiredBalance - actualBalance);
        }
    }

    /**
     * @notice Check if bonding period is active
     * @return true if bonding period is active
     */
    function isBondingPeriodActive() external view returns (bool) {
        return block.timestamp <= endOfBondingPeriod;
    }

    /**
     * @notice Check if bond has matured
     * @return true if bond has matured
     */
    function isBondMatured() external view returns (bool) {
        return block.timestamp >= maturityTimestamp;
    }

    /**
     * @notice Get contract's WCO balance
     * @return Contract's WCO balance
     */
    function getContractBalance() external view returns (uint256) {
        return address(this).balance;
    }

    // Prevent accidental WCO transfers
    receive() external payable {
        revert("Direct WCO transfers not allowed");
    }

    fallback() external payable {
        revert("Direct WCO transfers not allowed");
    }
}
