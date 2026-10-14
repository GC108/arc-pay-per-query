// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {PayPerQuery} from "../src/PayPerQuery.sol";

/// Pays for one query: PayPerQuery(CONTRACT_ADDRESS).pay{value: price}(QUERY_HASH).
/// Used by scripts/e2e-*.sh to play the "agent" role. Key read from env, never argv.
contract Pay is Script {
    function run() external {
        PayPerQuery ppq = PayPerQuery(payable(vm.envAddress("CONTRACT_ADDRESS")));
        bytes32 qh = vm.envBytes32("QUERY_HASH");
        uint256 price = ppq.price();
        vm.startBroadcast(vm.envUint("ARC_PAYER_PRIVATE_KEY"));
        uint256 id = ppq.pay{value: price}(qh);
        vm.stopBroadcast();
        console.log("receiptId", id);
    }
}
