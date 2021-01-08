/**
 * @type import('hardhat/config').HardhatUserConfig
 */

require("@nomiclabs/hardhat-waffle");


module.exports = {
  solidity: {
    compilers: [
      {
        version: "0.6.12"
      },
      {
        version: "0.5.16"
      }
    ]
  }
}
