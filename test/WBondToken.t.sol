// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "forge-std/Test.sol";
import "../src/WBondToken.sol";

contract MockStakingACM {
    mapping(bytes32 => mapping(address => bool)) public roles;
    
    function grantRole(bytes32 role, address account) external {
        roles[role][account] = true;
    }
    
    function hasRole(bytes32 role, address account) external view returns (bool) {
        return roles[role][account];
    }
}

contract WBondTokenTest is Test {
    WBondToken public bondToken;
    MockStakingACM public stakingACM;
    address public admin = address(0x1);
    address public treasury = address(0x2);
    address public user1 = address(0x3);
    address public user2 = address(0x4);
    
    uint256 public constant BONDING_PERIOD = 7 days;
    uint256 public constant MATURITY_PERIOD = 30 days;
    uint256 public constant YIELD_BPS = 500; // 5%
    
    function setUp() public {
        stakingACM = new MockStakingACM();
        stakingACM.grantRole(0x00, admin);
        
        uint256 endOfBonding = block.timestamp + BONDING_PERIOD;
        uint256 maturity = block.timestamp + MATURITY_PERIOD;
        
        bondToken = new WBondToken(
            "Bond Token",
            "BOND",
            endOfBonding,
            maturity,
            YIELD_BPS,
            address(stakingACM),
            treasury
        );
        
        // Give users and admin some ETH
        vm.deal(user1, 10 ether);
        vm.deal(user2, 5 ether);
        vm.deal(admin, 10 ether);
    }
    
    function testDeposit() public {
        vm.prank(user1);
        bondToken.deposit{value: 1 ether}();
        
        assertEq(bondToken.balanceOf(user1), 1 ether);
        assertEq(bondToken.getUserDeposit(user1), 1 ether);
        assertEq(bondToken.totalSupply(), 1 ether);
    }
    
    function testDepositAfterBondingPeriod() public {
        // Move time past bonding period
        vm.warp(block.timestamp + BONDING_PERIOD + 1);
        
        vm.prank(user1);
        vm.expectRevert(WBondToken.BondingPeriodEnded.selector);
        bondToken.deposit{value: 1 ether}();
    }
    
    function testClaimAfterMaturity() public {
        // Deposit during bonding period
        vm.prank(user1);
        bondToken.deposit{value: 1 ether}();
        
        // Fund the contract with additional ETH for yield payment using treasuryRepay
        uint256 expectedYield = (1 ether * YIELD_BPS) / 10000;
        vm.prank(admin);
        bondToken.treasuryRepay{value: expectedYield}();
        
        // Move time to maturity
        vm.warp(block.timestamp + MATURITY_PERIOD + 1);
        
        uint256 balanceBefore = user1.balance;
        
        vm.prank(user1);
        bondToken.claim();
        
        uint256 expectedTotal = 1 ether + expectedYield;
        
        assertEq(user1.balance, balanceBefore + expectedTotal);
        assertEq(bondToken.balanceOf(user1), 0);
        assertEq(bondToken.getUserDeposit(user1), 0);
    }
    
    function testClaimBeforeMaturity() public {
        vm.prank(user1);
        bondToken.deposit{value: 1 ether}();
        
        vm.prank(user1);
        vm.expectRevert(WBondToken.BondNotMatured.selector);
        bondToken.claim();
    }
    
    function testWithdrawToTreasury() public {
        // Deposit some ETH
        vm.prank(user1);
        bondToken.deposit{value: 1 ether}();
        
        uint256 treasuryBalanceBefore = treasury.balance;
        
        vm.prank(admin);
        bondToken.withdrawToTreasury();
        
        assertEq(treasury.balance, treasuryBalanceBefore + 1 ether);
    }
    
    function testUnauthorizedWithdraw() public {
        vm.prank(user1);
        vm.expectRevert(WBondToken.Unauthorized.selector);
        bondToken.withdrawToTreasury();
    }
    
    function testUpdateTreasuryAddress() public {
        address newTreasury = address(0x5);
        
        vm.prank(admin);
        bondToken.updateTreasuryAddress(newTreasury);
        
        assertEq(bondToken.treasuryAddress(), newTreasury);
    }
    
    function testGetExpectedPayout() public {
        vm.prank(user1);
        bondToken.deposit{value: 1 ether}();
        
        (uint256 principal, uint256 yieldAmount) = bondToken.getExpectedPayout(user1);
        
        assertEq(principal, 1 ether);
        assertEq(yieldAmount, (1 ether * YIELD_BPS) / 10000);
    }
    
    function testReceiveReverts() public {
        vm.prank(user1);
        vm.expectRevert("Direct ETH transfers not allowed");
        address(bondToken).call{value: 1 ether}("");
    }
    
    function testTreasuryRepay() public {
        // Deposit some ETH first
        vm.prank(user1);
        bondToken.deposit{value: 1 ether}();
        
        uint256 requiredAmount = bondToken.getRequiredBalance();
        uint256 currentBalance = address(bondToken).balance;
        uint256 needed = requiredAmount - currentBalance;
        
        vm.prank(admin);
        bondToken.treasuryRepay{value: needed}();
        
        assertEq(address(bondToken).balance, requiredAmount);
    }
    
    function testTreasuryRepayWithExcess() public {
        // Deposit some ETH first
        vm.prank(user1);
        bondToken.deposit{value: 1 ether}();
        
        uint256 requiredAmount = bondToken.getRequiredBalance();
        uint256 currentBalance = address(bondToken).balance;
        uint256 needed = requiredAmount - currentBalance;
        uint256 excess = 0.1 ether;
        
        uint256 adminBalanceBefore = admin.balance;
        
        vm.prank(admin);
        bondToken.treasuryRepay{value: needed + excess}();
        
        // Should refund excess
        assertEq(admin.balance, adminBalanceBefore - needed);
        assertEq(address(bondToken).balance, requiredAmount);
    }
    
    function testGetOffsetCounter() public {
        // Deposit some ETH
        vm.prank(user1);
        bondToken.deposit{value: 1 ether}();
        
        // Should be negative (underfunded)
        int256 offset = bondToken.getOffsetCounter();
        assertTrue(offset < 0);
        
        // Fund with treasury repay
        uint256 requiredAmount = bondToken.getRequiredBalance();
        uint256 currentBalance = address(bondToken).balance;
        uint256 needed = requiredAmount - currentBalance;
        
        vm.prank(admin);
        bondToken.treasuryRepay{value: needed}();
        
        // Should be zero (fully funded)
        offset = bondToken.getOffsetCounter();
        assertEq(offset, 0);
    }
    
    function testGetRequiredBalance() public {
        vm.prank(user1);
        bondToken.deposit{value: 1 ether}();
        
        uint256 expectedYield = (1 ether * YIELD_BPS) / 10000;
        uint256 expectedRequired = 1 ether + expectedYield;
        
        assertEq(bondToken.getRequiredBalance(), expectedRequired);
    }
}