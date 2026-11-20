module Main (main) where

import Control.Concurrent (forkIO, newEmptyMVar, putMVar, readMVar, takeMVar)
import Control.Exception (IOException, bracket, try)
import Control.Monad (forM, forM_, unless)
import qualified Data.ByteString as BS
import Data.List (partition)
import System.Directory
import System.Environment (getArgs)
import System.Exit (exitFailure)
import System.FilePath ((</>))
import System.IO (IOMode (ReadMode), hClose, openBinaryTempFile, withBinaryFile)
import System.IO.Error (isAlreadyInUseError)
import System.Info (compilerName, compilerVersion, os)

main :: IO ()
main = do
  putStrLn $ os ++ " / " ++ compilerName ++ " " ++ show compilerVersion
  args <- getArgs
  case args of
    ["overlap"] -> withScratch overlap
    ["stress"] -> withScratch stress
    _ -> error "Usage: copy-race overlap | copy-race stress (run from repository root)"

-- Force source reads to overlap without altering copyFile or the fixture.
-- Windows copyFile requests an exclusive RTS lock and conflicts with this
-- existing reader; POSIX copyFile requests a shared read lock and succeeds.
overlap :: FilePath -> IO ()
overlap dir = do
  let source = "test/data/HoverLibrary/hover-library.agda-lib"
      dest = dir </> "copied.agda-lib"
  withBinaryFile source ReadMode $ \_ -> do
    result <- tryIO $ copyFile source dest
    putStrLn $ "copyFile while source is open for reading: " ++ show result
    control <- tryIO $ BS.readFile source >>= BS.writeFile dest
    putStrLn $ "ByteString copy with the same reader: " ++ show control
    original <- BS.readFile source
    copied <- BS.readFile dest
    unless (original == copied) $ error "ByteString control changed the contents"
    case (os, result, control) of
      ("mingw32", Left e, Right ()) | isAlreadyInUseError e ->
        putStrLn "REPRODUCED: copyFile rejects a concurrent source reader."
      ("mingw32", _, _) -> do
        putStrLn "NOT REPRODUCED with this Windows runtime."
        exitFailure
      (_, Right (), Right ()) ->
        putStrLn "POSIX CONTROL PASSED; this does not reproduce the Windows failure."
      _ -> exitFailure

-- Same copyTree implementation as test/Test/Hover.hs, exercised without
-- starting ALS. Each worker has a separate destination and shared sources.
copyTree :: FilePath -> FilePath -> IO ()
copyTree from to = do
  createDirectoryIfMissing True to
  entries <- listDirectory from
  forM_ entries $ \entry -> do
    isDirectory <- doesDirectoryExist (from </> entry)
    if isDirectory
      then copyTree (from </> entry) (to </> entry)
      else copyFile (from </> entry) (to </> entry)

stress :: FilePath -> IO ()
stress dir = do
  let workers = 32 :: Int
      rounds = 100 :: Int
  counts <- forM ["Hover", "HoverLibrary"] $ \fixture -> do
    results <- fmap concat $ forM [1 .. rounds] $ \_ -> do
      start <- newEmptyMVar
      completions <- forM [1 .. workers] $ \worker -> do
        done <- newEmptyMVar
        _ <- forkIO $ do
          readMVar start
          result <- tryIO $ copyTree ("test/data" </> fixture) (dir </> fixture </> show worker)
          putMVar done result
        pure done
      putMVar start ()
      mapM takeMVar completions
    let (failures, successes) = partition isFailure results
    putStrLn $ fixture ++ ": " ++ show (length successes) ++ " successful copies; " ++ show (length failures) ++ " failures"
    mapM_ print (take 10 failures)
    pure (length failures)
  unless (sum counts == 0) exitFailure
  putStrLn "No failures observed; a passing stress run cannot rule out the race."
  where
    isFailure (Left _) = True
    isFailure _ = False

tryIO :: IO a -> IO (Either IOException a)
tryIO = try

withScratch :: (FilePath -> IO a) -> IO a
withScratch = bracket create removeDirectoryRecursive
  where
    create = do
      temp <- getTemporaryDirectory
      (path, handle) <- openBinaryTempFile temp "als-copy-race"
      hClose handle
      removeFile path
      createDirectory path
      pure path
