# masterfarmer-restaking

Restaking implementation for master farmer. This was developed in a hardhat environment.

The implementation consists of a set of interfaces, abstract contracts, and contracts that can be used to build a restaking adapter contract specific to a target farm's `_pid`. For MasterChef style farms, the only change needed is often for the pending tokens formula. Changes may not be necessary at all for StakingRewards style farming contracts.

See [./contracts/MasterChef_reference_implementation.sol](./contracts/MasterChef_reference_implementation.sol) and diff against sushiswap's original MasterChef.sol to see necessary changes.

See [./contracts/libraries/restaking/PickleAdapter.sol](./contracts/libraries/restaking/PickleAdapter.sol) for a MasterChef style adapter

See [./contracts/libraries/restaking/HarvestAdapter.sol](./contracts/libraries/restaking/HarvestAdapter.sol) for a StakingRewards style adapter