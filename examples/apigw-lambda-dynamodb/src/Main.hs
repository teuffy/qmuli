{-# LANGUAGE DeriveGeneric       #-}
{-# LANGUAGE NamedFieldPuns      #-}
{-# LANGUAGE OverloadedStrings   #-}
{-# LANGUAGE ScopedTypeVariables #-}

module Main where

import           Control.Lens                hiding (view, (.=))
import           Control.Monad               (void, (<=<))
import           Data.Aeson
import           Data.Aeson.Types            (typeMismatch)
import qualified Data.ByteString.Char8       as BS
import qualified Data.ByteString.Lazy        as LBS
import qualified Data.HashMap.Strict         as SHM
import           Data.Text                   (Text)
import           GHC.Generics
import           Network.AWS.DynamoDB        (AttributeValue, attributeValue,
                                              avS)

import           Qi                          (withConfig)
import           Qi.Config.AWS.Api           (ApiEvent (..),
                                              ApiVerb (Get, Post),
                                              RequestBody (..), aeBody,
                                              aeParams, rpPath)
import           Qi.Config.AWS.DDB           (DdbAttrDef (..), DdbAttrType (..),
                                              DdbProvCap (..))
import           Qi.Config.Identifier        (DdbTableId)
import           Qi.Program.Config.Interface (ConfigProgram)
import qualified Qi.Program.Config.Interface as CI
import           Qi.Program.Lambda.Interface (LambdaProgram, getDdbRecord,
                                              output, putDdbRecord)

-- Used the two curl commands below to test-drive the two endpoints (substitute your unique api stage url first):
--
-- curl -v -X POST -H "Content-Type: application/json" -d "{\"name\": \"cup\", \"shape\": \"round\", \"size\": 3}" "https://rd2nb7yjxh.execute-api.us-east-1.amazonaws.com/v1/things/mycup"
-- curl -v -X GET "https://rd2nb7yjxh.execute-api.us-east-1.amazonaws.com/v1/things/mycup"
--


data Thing = Thing {
    name  :: Text
  , shape :: Text
  , size  :: Int
} deriving (Generic, Show)

instance ToJSON Thing where
  toEncoding = genericToEncoding defaultOptions

instance FromJSON Thing where


newtype DdbThing = DdbThing {unDdbThing :: Thing}

instance ToJSON DdbThing where
  toJSON (DdbThing Thing{name, shape, size}) =
    object [
      "M" .= object [
              "name"  .= asString name
            , "shape" .= asString shape
            , "size"  .= asNumber size
            ]
    ]

asNumber :: Show a => a -> Value
asNumber n = object ["N" .= show n]

asString :: ToJSON a => a -> Value
asString s = object ["S" .= s]


instance FromJSON DdbThing where
  parseJSON (Object v) = do
    obj <- v .: "M"
    DdbThing <$> (
          Thing
            <$> ((.: "name")  =<< obj .: "S")
            <*> ((.: "shape") =<< obj .: "S")
            <*> ((.: "size")  =<< obj .: "N")
        )
  -- A non-Object value is of the wrong type, so fail.
  parseJSON invalid = typeMismatch "DdbThing" invalid



castFromDdbAttrs
  :: (FromJSON a, ToJSON b, FromJSON c)
  => (a -> b)
  -> AttributeValue
  -> Result c
castFromDdbAttrs ddbDeconstructor = fromJSON <=< fmap (toJSON . ddbDeconstructor) . fromJSON . toJSON

castToDdbAttrs
  :: (FromJSON a, ToJSON b)
  => (a -> b)
  -> Value
  -> Result AttributeValue
castToDdbAttrs ddbConstructor = fromJSON <=< fmap (toJSON . ddbConstructor) . fromJSON



main :: IO ()
main =
  "apigwlambda" `withConfig` config

    where
      config :: ConfigProgram ()
      config = do
        api     <- CI.api "world"
        things  <- CI.apiRootResource "things" api
        thing   <- CI.apiChildResource "{thingId}" things

        thingsTable <- CI.ddbTable "things" (DdbAttrDef "Id" S) Nothing (DdbProvCap 1 1)

        void $ CI.apiMethodLambda
          "getProp"
          Get
          thing
          $ getThingLambda thingsTable

        void $ CI.apiMethodLambda
          "putProp"
          Post
          thing
          $ putThingLambda thingsTable


      getThingLambda
        :: DdbTableId
        -> ApiEvent
        -> LambdaProgram ()
      getThingLambda ddbTableId event@ApiEvent{} = do
        withId event $ \tid -> do
          let keys = SHM.fromList [
                  ("Id", attributeValue & avS .~ Just tid)
                ]
          ddbRecord <- getDdbRecord ddbTableId keys
          case SHM.lookup "Data" ddbRecord of
            Just thingAttrs -> do
              case castFromDdbAttrs unDdbThing thingAttrs of
                Success (thing :: Thing)  ->
                  output . LBS.toStrict . encode $ thing
                Error err                 ->
                  output . BS.pack $ "Error: fromJson: " ++ err

            Nothing ->
              output . BS.pack $ "Error: could not extract thing data, DDB record was: " ++ show ddbRecord



      putThingLambda
        :: DdbTableId
        -> ApiEvent
        -> LambdaProgram ()
      putThingLambda ddbTableId event@ApiEvent{} = do
        withId event $ \tid -> do
          withThingAttributes event $ \thingAttrs -> do
            let item = SHM.fromList [
                    ("Id",    attributeValue & avS .~ Just tid)
                  , ("Data",  thingAttrs)
                  ]

            putDdbRecord ddbTableId item
            output "successfully added item"


      withThingAttributes
        :: ApiEvent
        -> (AttributeValue -> LambdaProgram ())
        -> LambdaProgram ()
      withThingAttributes event f = case event^.aeBody of
        JsonBody jb -> case castToDdbAttrs DdbThing jb of
          Success thing -> f thing
          Error err     -> output . BS.pack $ "Error: fromJson: " ++ err
        unexpected  ->
          output . BS.pack $ "Unexpected request body: " ++ show unexpected

      withId event f = case SHM.lookup "thingId" $ event^.aeParams.rpPath of
        Just (String x) -> f x
        Just unexpected ->
          output $ BS.pack $ "unexpected path parameter: " ++ show unexpected
        Nothing ->
          output "expected path parameter 'thingId' was not found"



