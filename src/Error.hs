{-# LANGUAGE OverloadedStrings #-}

module Main where

import           Ceilometer.Process

main :: IO ()
main = runErrorCollector
