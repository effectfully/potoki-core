module Potok.Core.Fetcher where

import Potok.Prelude
import qualified Data.Attoparsec.Types as I
import qualified Data.Attoparsec.ByteString as K
import qualified Data.Attoparsec.Text as L


newtype Fetcher element =
  {-|
  Church encoding of @IO (Maybe element)@.
  -}
  Fetcher (forall x. IO x -> (element -> IO x) -> IO x)

instance Functor Fetcher where
  fmap mapping (Fetcher fetcherFn) =
    Fetcher (\signalEnd signalElement -> fetcherFn signalEnd (signalElement . mapping))

instance Applicative Fetcher where
  pure x =
    Fetcher (\signalEnd signalElement -> signalElement x)
  (<*>) (Fetcher leftFn) (Fetcher rightFn) =
    Fetcher (\signalEnd signalElement -> leftFn signalEnd (\leftElement -> rightFn signalEnd (\rightElement -> signalElement (leftElement rightElement))))

instance Monad Fetcher where
  return =
    pure
  (>>=) (Fetcher leftFn) rightK =
    Fetcher
    (\signalEnd onRightElement ->
      leftFn signalEnd
      (\leftElement -> case rightK leftElement of
        Fetcher rightFn -> rightFn signalEnd onRightElement))

instance Alternative Fetcher where
  empty =
    Fetcher (\signalEnd signalElement -> signalEnd)
  (<|>) (Fetcher leftSignal) (Fetcher rightSignal) =
    Fetcher (\signalEnd signalElement -> leftSignal (rightSignal signalEnd signalElement) signalElement)

mapWithParseResult :: forall input parsed. (input -> I.IResult input parsed) -> Fetcher input -> IO (Fetcher (Either Text parsed))
mapWithParseResult inputToResult (Fetcher fetchInput) =
  do
    unconsumedStateRef <- newIORef Nothing
    return (Fetcher (fetchParsed unconsumedStateRef))
  where
    fetchParsed :: IORef (Maybe input) -> IO x -> (Either Text parsed -> IO x) -> IO x
    fetchParsed unconsumedStateRef onParsedEnd onParsedElement =
      do
        unconsumedState <- readIORef unconsumedStateRef
        case unconsumedState of
          Just unconsumed -> matchResult (inputToResult unconsumed)
          Nothing -> consume inputToResult
      where
        matchResult =
          \case
            I.Partial inputToResult ->
              consume inputToResult
            I.Done unconsumed parsed ->
              do
                writeIORef unconsumedStateRef (Just unconsumed)
                onParsedElement (Right parsed)
            I.Fail unconsumed contexts message ->
              do
                writeIORef unconsumedStateRef (Just unconsumed)
                onParsedElement (Left (fromString (intercalate " > " contexts <> ": " <> message)))
        consume inputToResult =
          fetchInput onParsedEnd (matchResult . inputToResult)

{-|
Lift an Attoparsec ByteString parser.

Consumption is non-greedy and terminates when the parser is done.
-}
{-# INLINE parseBytes #-}
parseBytes :: K.Parser parsed -> Fetcher ByteString -> IO (Fetcher (Either Text parsed))
parseBytes parser =
  mapWithParseResult (K.parse parser)

{-|
Lift an Attoparsec Text parser.

Consumption is non-greedy and terminates when the parser is done.
-}
{-# INLINE parseText #-}
parseText :: L.Parser parsed -> Fetcher Text -> IO (Fetcher (Either Text parsed))
parseText parser =
  mapWithParseResult (L.parse parser)

duplicate :: Fetcher element -> IO (Fetcher element, Fetcher element)
duplicate (Fetcher fetchInput) =
  undefined

take :: Int -> Fetcher element -> IO (Fetcher element)
take amount (Fetcher fetchInput) =
  fetcher <$> newIORef amount
  where
    fetcher countRef =
      Fetcher $ \signalEnd signalElement -> do
        count <- readIORef countRef
        if count > 0
          then do
            writeIORef countRef (pred count)
            fetchInput signalEnd signalElement
          else signalEnd

sink :: (Fetcher input -> IO output) -> Fetcher input -> IO (Fetcher output)
sink sink (Fetcher signal) =
  fetcher <$> newIORef False
  where
    fetcher finishedRef =
      Fetcher $ \signalEnd signalOutput -> do
        finished <- readIORef finishedRef
        if finished
          then signalEnd
          else do
            output <-
              sink $ Fetcher $ \sinkSignalEnd sinkSignalInput ->
              signal (writeIORef finishedRef True >> sinkSignalEnd) sinkSignalInput
            signalOutput output
