{-# LANGUAGE OverloadedStrings #-}

module Main where

import           Vaultaire.Collector.Ceilometer.Process

main :: IO ()
main = runCollector
