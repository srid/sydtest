{-# LANGUAGE DataKinds #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeFamilies #-}

module Test.Syd.AroundCombinationSpec (spec) where

import Control.Concurrent.STM
import Control.Monad.IO.Class
import Test.Syd

spec :: Spec
spec = sequential $
  doNotRandomiseExecutionOrder $ do
    describe "aroundAll + aroundAllWith + around + aroundWith'" $ do
      var <- liftIO $ newTVarIO (0 :: Int)
      let readAndIncrement :: IO Int
          readAndIncrement = atomically $ stateTVar var $ \i -> (i + 1, i + 1)
      let increment :: IO ()
          increment = atomically $ modifyTVar var (+ 1)
      let incrementAround :: (Int -> IO s) -> IO s
          incrementAround func = do
            i <- readAndIncrement
            s <- func i
            increment
            pure s
      let incrementAroundWith :: (Int -> IO s) -> Int -> IO s
          incrementAroundWith func j = do
            i <- readAndIncrement
            s <- func (i + j)
            increment
            pure s
      let incrementAroundWith2 :: (Int -> Int -> IO ()) -> Int -> Int -> IO ()
          incrementAroundWith2 func j k = do
            i <- readAndIncrement
            func (i + j) k
            increment
      aroundAll incrementAround $
        aroundAllWith incrementAroundWith $
          around incrementAround $
            aroundWith' incrementAroundWith2 $ do
              itWithBoth "reads correctly" $
                \i k ->
                  (i, k) `shouldBe` (3, 3)
              itWithBoth "reads correctly" $
                \i k ->
                  (i, k) `shouldBe` (3, 7)
