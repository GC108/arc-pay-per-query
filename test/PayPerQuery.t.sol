// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {PayPerQuery} from "../src/PayPerQuery.sol";

contract PayPerQueryTest is Test {
    PayPerQuery internal ppq;
    uint256 internal constant PRICE = 0.001 ether; // 0.001 USDC (native USDC = 18 decimals on Arc)
    address internal owner = makeAddr("owner");
    address internal agent = makeAddr("agent");
    bytes32 internal constant Q = keccak256("GET /v1/warn?limit=3&nonce=abc&state=TX");

    event QueryPaid(bytes32 indexed queryHash, address indexed payer, uint256 amount, uint256 receiptId);

    function setUp() public {
        vm.prank(owner);
        ppq = new PayPerQuery(PRICE);
        vm.deal(agent, 1 ether);
    }

    function test_PayRecordsReceiptAndEmits() public {
        vm.expectEmit(true, true, false, true, address(ppq));
        emit QueryPaid(Q, agent, PRICE, 1);
        vm.prank(agent);
        uint256 id = ppq.pay{value: PRICE}(Q);
        assertEq(id, 1);
        (address payer, uint96 amount, uint64 paidAt) = ppq.receipts(Q);
        assertEq(payer, agent);
        assertEq(amount, PRICE);
        assertEq(paidAt, block.timestamp);
        assertEq(address(ppq).balance, PRICE);
        assertTrue(ppq.isPaid(Q, 1 days));
    }

    function test_RevertWhen_WrongAmount() public {
        vm.prank(agent);
        vm.expectRevert(abi.encodeWithSelector(PayPerQuery.WrongAmount.selector, PRICE - 1, PRICE));
        ppq.pay{value: PRICE - 1}(Q);
        // 6-decimal mistake: 0.001 USDC in ERC-20 units sent as native value
        vm.prank(agent);
        vm.expectRevert(abi.encodeWithSelector(PayPerQuery.WrongAmount.selector, 1000, PRICE));
        ppq.pay{value: 1000}(Q);
    }

    function test_RevertWhen_QueryPaidTwice() public {
        vm.prank(agent);
        ppq.pay{value: PRICE}(Q);
        vm.prank(agent);
        vm.expectRevert(abi.encodeWithSelector(PayPerQuery.AlreadyPaid.selector, Q));
        ppq.pay{value: PRICE}(Q);
    }

    function test_IsPaidExpires() public {
        vm.prank(agent);
        ppq.pay{value: PRICE}(Q);
        vm.warp(block.timestamp + 1 days + 1);
        assertFalse(ppq.isPaid(Q, 1 days));
        assertFalse(ppq.isPaid(keccak256("unpaid"), 1 days));
    }

    function test_DirectTransferReverts() public {
        vm.prank(agent);
        (bool ok,) = address(ppq).call{value: PRICE}("");
        assertFalse(ok);
    }

    function test_OwnerWithdraw() public {
        vm.prank(agent);
        ppq.pay{value: PRICE}(Q);
        address payable sink = payable(makeAddr("sink"));
        vm.prank(owner);
        ppq.withdraw(sink);
        assertEq(sink.balance, PRICE);
        assertEq(address(ppq).balance, 0);
    }

    function test_RevertWhen_NonOwnerAdmin() public {
        vm.startPrank(agent);
        vm.expectRevert(PayPerQuery.NotOwner.selector);
        ppq.withdraw(payable(agent));
        vm.expectRevert(PayPerQuery.NotOwner.selector);
        ppq.setPrice(1);
        vm.stopPrank();
    }

    function test_RevertWhen_WithdrawToZero() public {
        vm.prank(owner);
        vm.expectRevert(PayPerQuery.ZeroAddress.selector);
        ppq.withdraw(payable(address(0)));
    }

    function test_SetPriceAndTwoStepOwnership() public {
        vm.prank(owner);
        ppq.setPrice(2 * PRICE);
        assertEq(ppq.price(), 2 * PRICE);
        vm.prank(owner);
        ppq.transferOwnership(agent);
        assertEq(ppq.owner(), owner);
        vm.prank(agent);
        ppq.acceptOwnership();
        assertEq(ppq.owner(), agent);
    }

    function testFuzz_OnlyExactPriceAccepted(uint96 value) public {
        vm.assume(value != PRICE && value <= 1 ether);
        vm.prank(agent);
        vm.expectRevert(abi.encodeWithSelector(PayPerQuery.WrongAmount.selector, uint256(value), PRICE));
        ppq.pay{value: value}(Q);
    }
}
