{-# LANGUAGE DataKinds #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NumericUnderscores #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE TypeOperators #-}

-- | This module defines how to run a test suite
module Test.Syd.Runner where

import Control.Concurrent (getNumCapabilities)
import Control.Concurrent.QSem
import Control.Monad.Reader
import qualified Data.ByteString as SB
import qualified Data.ByteString.Char8 as SB8
import qualified Data.Text as T
import Rainbow
import Test.QuickCheck.IO ()
import Test.Syd.Def
import Test.Syd.HList
import Test.Syd.OptParse
import Test.Syd.Output
import Test.Syd.Run
import Test.Syd.SpecDef
import Test.Syd.SpecForest
import UnliftIO

sydTestResult :: Settings -> TestDefM '[] () r -> IO ResultForest
sydTestResult sets spec = do
  specForest <- execTestDefM sets spec
  case settingThreads sets of
    Synchronous -> runSpecForestInterleavedWithOutputSynchronously specForest
    ByCapabilities -> do
      i <- getNumCapabilities
      runSpecForestInterleavedWithOutputAsynchronously i specForest
    Asynchronous i ->
      runSpecForestInterleavedWithOutputAsynchronously i specForest

runSpecForestSynchronously :: TestForest '[] () -> IO ResultForest
runSpecForestSynchronously = goForest HNil
  where
    goForest :: HList a -> TestForest a () -> IO ResultForest
    goForest l = mapM (goTree l)
    goTree :: forall a. HList a -> TestTree a () -> IO ResultTree
    goTree l = \case
      DefDescribeNode t sdf -> DescribeNode t <$> goForest l sdf
      DefSpecifyNode t td () -> do
        let runFunc = testDefVal td (\f -> f l ())
        result <- runFunc
        let td' = td {testDefVal = result}
        pure $ SpecifyNode t td'
      DefWrapNode func sdf -> SubForestNode <$> applySimpleWrapper'' func (goForest l sdf)
      DefBeforeAllNode func sdf -> do
        SubForestNode
          <$> ( do
                  b <- func
                  goForest (HCons b l) sdf
              )
      DefBeforeAllWithNode func sdf -> do
        SubForestNode
          <$> ( do
                  let HCons x _ = l
                  b <- func x
                  goForest (HCons b l) sdf
              )
      DefAroundAllNode func sdf ->
        SubForestNode <$> applySimpleWrapper' func (\b -> goForest (HCons b l) sdf)
      DefAroundAllWithNode func sdf ->
        let HCons x _ = l
         in SubForestNode <$> applySimpleWrapper func (\b -> goForest (HCons b l) sdf) x
      DefAfterAllNode func sdf -> SubForestNode <$> (goForest l sdf `finally` func l)
      DefParallelismNode _ sdf -> SubForestNode <$> goForest l sdf -- Ignore, it's synchronous anyway

runSpecForestInterleavedWithOutputSynchronously :: TestForest '[] () -> IO ResultForest
runSpecForestInterleavedWithOutputSynchronously testForest = do
  byteStringMaker <- liftIO byteStringMakerFromEnvironment
  let outputLine :: [Chunk] -> IO ()
      outputLine lineChunks = do
        let bss = chunksToByteStrings byteStringMaker lineChunks
        liftIO $ do
          mapM_ SB.putStr bss
          SB8.putStrLn ""
  let pad :: Int -> [Chunk] -> [Chunk]
      pad level = (chunk (T.replicate (level * 2) " ") :)
      goTree :: Int -> HList a -> TestTree a () -> IO ResultTree
      goTree level a = \case
        DefDescribeNode t sf -> do
          outputLine $ pad level $ outputDescribeLine t
          DescribeNode t <$> goForest (succ level) a sf
        DefSpecifyNode t td () -> do
          let runFunc = testDefVal td (\f -> f a ())
          result <- runFunc
          let td' = td {testDefVal = result}
          mapM_ (outputLine . pad level) $ outputSpecifyLines t td'
          pure $ SpecifyNode t td'
        DefWrapNode func sdf -> SubForestNode <$> applySimpleWrapper'' func (goForest level a sdf)
        DefBeforeAllNode func sdf ->
          SubForestNode
            <$> ( do
                    b <- func
                    goForest level (HCons b a) sdf
                )
        DefBeforeAllWithNode func sdf ->
          SubForestNode
            <$> ( do
                    let HCons x _ = a
                    b <- func x
                    goForest level (HCons b a) sdf
                )
        DefAroundAllNode func sdf ->
          SubForestNode <$> applySimpleWrapper' func (\b -> goForest level (HCons b a) sdf)
        DefAroundAllWithNode func sdf ->
          let HCons x _ = a
           in SubForestNode <$> applySimpleWrapper func (\b -> goForest level (HCons b a) sdf) x
        DefAfterAllNode func sdf -> SubForestNode <$> (goForest level a sdf `finally` func a)
        DefParallelismNode _ sdf -> SubForestNode <$> goForest level a sdf -- Ignore, it's synchronous anyway
      goForest :: Int -> HList a -> TestForest a () -> IO ResultForest
      goForest level a = mapM (goTree level a)
  mapM_ outputLine outputTestsHeader
  resultForest <- goForest 0 HNil testForest
  outputLine $ [chunk " "]
  mapM_ outputLine $ outputFailuresWithHeading resultForest
  pure resultForest

-- This fails miserably when silencing is used.
runSpecForestInterleavedWithOutputAsynchronously :: Int -> TestForest '[] () -> IO ResultForest
runSpecForestInterleavedWithOutputAsynchronously nbThreads testForest = do
  handleForest <- makeHandleForest testForest
  let runRunner = runner nbThreads handleForest
      runPrinter = liftIO $ printer handleForest
  ((), resultForest) <- concurrently runRunner runPrinter
  pure resultForest

type HandleForest a b = SpecDefForest a b (MVar TestRunResult)

type HandleTree a b = SpecDefTree a b (MVar TestRunResult)

makeHandleForest :: TestForest a b -> IO (HandleForest a b)
makeHandleForest = traverse $
  traverse $ \() -> do
    var <- newEmptyMVar
    pure var

runner :: Int -> HandleForest '[] () -> IO ()
runner nbThreads handleForest = do
  sem <- liftIO $ newQSem nbThreads
  let goForest :: Parallelism -> HList a -> HandleForest a () -> IO ()
      goForest p a = mapM_ (goTree p a)
      goTree :: Parallelism -> HList a -> HandleTree a () -> IO ()
      goTree p a = \case
        DefDescribeNode _ sdf -> goForest p a sdf
        DefSpecifyNode _ td var -> do
          let runNow = testDefVal td (\f -> f a ())
          case p of
            Parallel -> do
              liftIO $ waitQSem sem
              let job :: IO ()
                  job = do
                    result <- runNow
                    putMVar var result
                    liftIO $ signalQSem sem
              jobAsync <- async job
              link jobAsync
            Sequential -> do
              result <- runNow
              putMVar var result
        DefWrapNode func sdf -> func (goForest p a sdf)
        DefBeforeAllNode func sdf -> do
          b <- func
          goForest p (HCons b a) sdf
        DefBeforeAllWithNode func sdf -> do
          let HCons x _ = a
          b <- func x
          goForest p (HCons b a) sdf
        DefAroundAllNode func sdf ->
          func (\b -> goForest p (HCons b a) sdf)
        DefAroundAllWithNode func sdf ->
          let HCons x _ = a
           in func (\b -> goForest p (HCons b a) sdf) x
        DefAfterAllNode func sdf -> goForest p a sdf `finally` func a
        DefParallelismNode p' sdf -> goForest p' a sdf
  goForest Parallel HNil handleForest

printer :: HandleForest '[] () -> IO ResultForest
printer handleForest = do
  byteStringMaker <- liftIO byteStringMakerFromEnvironment
  let outputLine :: [Chunk] -> IO ()
      outputLine lineChunks = do
        let bss = chunksToByteStrings byteStringMaker lineChunks
        mapM_ SB.putStr bss
        SB8.putStrLn ""
  let pad :: Int -> [Chunk] -> [Chunk]
      pad level = (chunk (T.replicate (level * 2) " ") :)
      goTree :: Int -> HandleTree a b -> IO ResultTree
      goTree level = \case
        DefDescribeNode t sf -> do
          outputLine $ pad level $ outputDescribeLine t
          DescribeNode t <$> goForest (succ level) sf
        DefSpecifyNode t td var -> do
          result <- takeMVar var
          let td' = td {testDefVal = result}
          mapM_ (outputLine . pad level) $ outputSpecifyLines t td'
          pure $ SpecifyNode t td'
        DefWrapNode _ sdf -> SubForestNode <$> goForest level sdf
        DefBeforeAllNode _ sdf -> SubForestNode <$> goForest level sdf
        DefBeforeAllWithNode _ sdf -> SubForestNode <$> goForest level sdf
        DefAroundAllNode _ sdf -> SubForestNode <$> goForest level sdf
        DefAroundAllWithNode _ sdf -> SubForestNode <$> goForest level sdf
        DefAfterAllNode _ sdf -> SubForestNode <$> goForest level sdf
        DefParallelismNode _ sdf -> SubForestNode <$> goForest level sdf
      goForest :: Int -> HandleForest a b -> IO ResultForest
      goForest level = mapM (goTree level)
  mapM_ outputLine $ outputTestsHeader
  resultForest <- goForest 0 handleForest
  outputLine $ [chunk " "]
  mapM_ outputLine $ outputFailuresWithHeading resultForest
  pure resultForest

applySimpleWrapper ::
  MonadIO m =>
  ((a -> m ()) -> (b -> m ())) ->
  (a -> m r) ->
  (b -> m r)
applySimpleWrapper takeTakeA takeA b = do
  var <- liftIO $ newEmptyMVar
  takeTakeA
    ( \a -> do
        r <- takeA a
        liftIO $ putMVar var r
    )
    b
  liftIO $ readMVar var

applySimpleWrapper' ::
  MonadIO m =>
  ((a -> m ()) -> m ()) ->
  (a -> m r) ->
  m r
applySimpleWrapper' takeTakeA takeA = do
  var <- liftIO $ newEmptyMVar
  takeTakeA
    ( \a -> do
        r <- takeA a
        liftIO $ putMVar var r
    )

  liftIO $ readMVar var

applySimpleWrapper'' ::
  MonadIO m =>
  (m () -> m ()) ->
  m r ->
  m r
applySimpleWrapper'' wrapper produceResult = do
  var <- liftIO $ newEmptyMVar
  wrapper $ do
    r <- produceResult
    liftIO $ putMVar var r

  liftIO $ readMVar var

applySimpleWrapper2 ::
  MonadIO m =>
  ((a -> b -> m ()) -> (c -> d -> m ())) ->
  (a -> b -> m r) ->
  (c -> d -> m r)
applySimpleWrapper2 takeTakeAB takeAB c d = do
  var <- liftIO $ newEmptyMVar
  takeTakeAB
    ( \a b -> do
        r <- takeAB a b
        liftIO $ putMVar var r
    )
    c
    d
  liftIO $ readMVar var
