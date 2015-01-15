vaultaire-collector-ceilometer
==============================

vaultaire-collector-ceilometer reads Ceilometer metrics via rabbitmq and writes
them to [Vaultaire](https://github.com/anchor/vaultaire). Designed to operate with
[ceilometer-publisher-rabbitmq](https://github.com/anchor/ceilometer-publisher-rabbitmq).


Dependencies
------------

 - [vaultaire-collector-common](https://github.com/anchor/vaultaire-collector-common)
 - [Marquise](https://github.com/anchor/marquise)
 - [vaultaire-common](https://github.com/anchor/vaultaire-common)

Installation + Deployment
-----------------------

1. Install from source using a cabal sandbox.
    ```
    git clone git@github.com:anchor/vaultaire-collector-ceilometer.git
    git clone git@github.com:anchor/vaultaire-collector-common.git
    git clone git@github.com:anchor/vaultaire-common.git
    git clone git@github.com:anchor/marquise.git
    cd vaultaire-collector-ceilometer
    cabal sandbox init
    cabal sandbox add-source ../vaultaire-collector-common ../vaultaire-common ../marquise
    cabal install --only-dependencies -j && cabal build
    ```

2. Run. The executable will be `dist/build/vaultaire-collector-ceilometer/vaultaire-collector-ceilometer`
