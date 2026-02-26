// SPDX-License-Identifier: MIT
// OpenZeppelin Contracts (last updated v5.2.0) (proxy/ERC1967/ERC1967Proxy.sol)

pragma solidity ^0.8.30;

import {Proxy} from "@openzeppelin/contracts/proxy/Proxy.sol";
import {ERC1967Utils} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Utils.sol";
import {StorageSlot} from "@openzeppelin/contracts/utils/StorageSlot.sol";

/**
 * @dev This contract implements an upgradeable proxy. It is upgradeable because calls are delegated to an
 * implementation address that can be changed. This address is stored in storage in the location specified by
 * https://eips.ethereum.org/EIPS/eip-1967[ERC-1967], so that it doesn't conflict with the storage layout of the
 * implementation behind the proxy.
 */
contract ERC1967Proxy is Proxy {
    /**
     * @dev Initializes the upgradeable proxy with an initial implementation specified by `implementation`.
     *
     * If `_data` is nonempty, it's used as data in a delegate call to `implementation`. This will typically be an
     * encoded function call, and allows initializing the storage of the proxy like a Solidity constructor.
     *
     * Requirements:
     *
     * - If `data` is empty, `msg.value` must be zero.
     */
    function initERC1967Proxy(address implementation, bytes memory _data) internal {
        ERC1967Utils.upgradeToAndCall(implementation, _data);
    }

    /**
     * @dev Returns the current implementation address.
     *
     * TIP: To get this value clients can read directly from the storage slot shown below (specified by ERC-1967) using
     * the https://eth.wiki/json-rpc/API#eth_getstorageat[`eth_getStorageAt`] RPC call.
     * `0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc`
     */
    function _implementation() internal view virtual override returns (address) {
        return ERC1967Utils.getImplementation();
    }
}

/**
 * @title ContractProxy
 * @dev  For PowerContractUpgradeable ERC1967 proxy
 */
contract ContractProxy is ERC1967Proxy {
    bytes32 internal constant INIT_SLOT = 0x2e654c1456f1ed51c1a211676c3e6087911f3becd2b4a081ec1a8d5dad8b8d22; //keccak256("ContractProxy.initialized") - 1
    function init(address implementation) public{
        require(!StorageSlot.getBooleanSlot(INIT_SLOT).value, "ContractProxy: already initialized");
        bytes memory _data = abi.encodeWithSignature("initialize()"); 
        StorageSlot.getBooleanSlot(INIT_SLOT).value = true;
        initERC1967Proxy(implementation, _data);
    }

    receive() external payable {
    }
    
}

