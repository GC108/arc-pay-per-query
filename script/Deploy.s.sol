// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {PayPerQuery} from "../src/PayPerQuery.sol";

/// Usage (key comes from the environment, never the command line):
///   set -a; . ~/.config/agent-income/arc-deployer.env; set +a
///   arc-forge script script/Deploy.s.sol:Deploy --rpc-url $RPC_URL --broadcast --network arc
/// The key is read via vm.envUint so it never appears in argv / shell history.
contract Deploy is Script {
    function run() external returns (PayPerQuery ppq) {
        uint256 priceWei = vm.envOr("PRICE_WEI", uint256(0.001 ether)); // 0.001 USDC
        vm.startBroadcast(vm.envUint("ARC_DEPLOYER_PRIVATE_KEY"));
        ppq = new PayPerQuery(priceWei);
        vm.stopBroadcast();
        console.log("PayPerQuery deployed at", address(ppq));
        console.log("price (native USDC wei, 18 decimals)", priceWei);
    }
}
