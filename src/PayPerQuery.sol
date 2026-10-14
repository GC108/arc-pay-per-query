// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// @title PayPerQuery
/// @notice On-chain payment receipts for a pay-per-query data API on Arc.
///         A caller (typically an AI agent) pays the per-query price in native USDC
///         (Arc's gas token, 18 decimals) and binds the payment to a `queryHash`:
///         keccak256 of the canonical API request. The API server verifies the
///         receipt on-chain before serving the record. One payment per queryHash.
/// @dev    Arc specifics (docs.arc.io/arc/references/evm-differences):
///         - msg.value is native USDC with 18 decimals (1 USDC = 1e18), NOT the 6-decimal
///           ERC-20 view at 0x3600...0000. Never mix the two.
///         - Native value sends can revert for blocklist reasons; withdraw() reverts loudly.
///         - Sends of value to address(0) revert, so withdraw() rejects address(0) up front.
contract PayPerQuery {
    struct Receipt {
        address payer;
        uint96 amount; // native USDC wei (18 decimals); uint96 caps at ~7.9e10 USDC
        uint64 paidAt; // block.timestamp
    }

    address public owner;
    address public pendingOwner;
    uint256 public price; // native USDC wei per query
    uint256 public receiptCount;

    mapping(bytes32 queryHash => Receipt) public receipts;

    event QueryPaid(bytes32 indexed queryHash, address indexed payer, uint256 amount, uint256 receiptId);
    event PriceChanged(uint256 oldPrice, uint256 newPrice);
    event Withdrawn(address indexed to, uint256 amount);
    event OwnershipTransferStarted(address indexed from, address indexed to);
    event OwnershipTransferred(address indexed from, address indexed to);

    error NotOwner();
    error WrongAmount(uint256 sent, uint256 price);
    error AlreadyPaid(bytes32 queryHash);
    error ZeroAddress();
    error WithdrawFailed();
    error DirectTransferNotAllowed();

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    constructor(uint256 initialPrice) {
        owner = msg.sender;
        price = initialPrice;
        emit OwnershipTransferred(address(0), msg.sender);
        emit PriceChanged(0, initialPrice);
    }

    /// @notice Pay for one query. msg.value must equal `price` exactly, so an agent
    ///         can't overpay by a decimals mistake (18 vs 6) without the tx reverting.
    function pay(bytes32 queryHash) external payable returns (uint256 receiptId) {
        if (msg.value != price) revert WrongAmount(msg.value, price);
        if (receipts[queryHash].payer != address(0)) revert AlreadyPaid(queryHash);
        receipts[queryHash] = Receipt(msg.sender, uint96(msg.value), uint64(block.timestamp));
        receiptId = ++receiptCount;
        emit QueryPaid(queryHash, msg.sender, msg.value, receiptId);
    }

    /// @notice Convenience view for verifiers that hold a queryHash but no tx hash.
    function isPaid(bytes32 queryHash, uint256 maxAgeSeconds) external view returns (bool) {
        Receipt memory r = receipts[queryHash];
        return r.payer != address(0) && block.timestamp - r.paidAt <= maxAgeSeconds;
    }

    function setPrice(uint256 newPrice) external onlyOwner {
        emit PriceChanged(price, newPrice);
        price = newPrice;
    }

    function withdraw(address payable to) external onlyOwner {
        if (to == address(0)) revert ZeroAddress();
        uint256 amount = address(this).balance;
        (bool ok,) = to.call{value: amount}("");
        if (!ok) revert WithdrawFailed();
        emit Withdrawn(to, amount);
    }

    function transferOwnership(address to) external onlyOwner {
        pendingOwner = to;
        emit OwnershipTransferStarted(owner, to);
    }

    function acceptOwnership() external {
        if (msg.sender != pendingOwner) revert NotOwner();
        emit OwnershipTransferred(owner, msg.sender);
        owner = msg.sender;
        pendingOwner = address(0);
    }

    /// @dev Plain transfers carry no queryHash, so they would be unattributable payments.
    receive() external payable {
        revert DirectTransferNotAllowed();
    }
}
