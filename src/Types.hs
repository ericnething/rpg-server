-- Roll2d6 Virtual Tabletop Project
--
-- Copyright (C) 2018-2019 Eric Nething <eric@roll2d6.org>
--
-- This program is free software: you can redistribute it
-- and/or modify it under the terms of the GNU Affero
-- General Public License as published by the Free Software
-- Foundation, either version 3 of the License, or (at your
-- option) any later version.
--
-- This program is distributed in the hope that it will be
-- useful, but WITHOUT ANY WARRANTY; without even the
-- implied warranty of MERCHANTABILITY or FITNESS FOR A
-- PARTICULAR PURPOSE.  See the GNU Affero General Public
-- License for more details.
--
-- You should have received a copy of the GNU Affero General
-- Public License along with this program. If not, see
-- <https://www.gnu.org/licenses/>.

{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE StandaloneDeriving #-}
{-# LANGUAGE ScopedTypeVariables #-}

module Types where

import           Data.Text (Text)
import qualified Data.Text as T (dropWhile, drop)
import           Data.Text.Lazy as LT (toStrict)

import Data.Aeson
  ( FromJSON(..)
  , ToJSON(..)
  , Value(..)
  , (.:)
  , (.=)
  , object
  , genericToEncoding
  , defaultOptions
  , pairs
  )
import Data.Aeson.Encoding (string)

import Database.PostgreSQL.Simple.FromRow
import Database.PostgreSQL.Simple.FromField
import Database.PostgreSQL.Simple.ToField
import Database.PostgreSQL.Simple.Errors (ConstraintViolation(..))
import Data.Int (Int64)

import           Data.UUID.Types (UUID)
import qualified Data.UUID.Types as UUID (fromText, toText)

import GHC.Generics
import Control.Applicative (empty, (<|>))
import Data.Maybe (fromJust)

import Web.HttpApiData (FromHttpApiData(..))

import qualified Data.Map.Strict as Map (member)
import           Data.Map.Strict (Map)
import           Data.Time (UTCTime)
import           Data.Time.Clock.POSIX (utcTimeToPOSIXSeconds)

import Control.Exception (throw)

import Config (Config)
import Servant (Handler)
import Control.Monad.Trans.Reader (ReaderT)


type App = ReaderT Config Handler

------------------------------------------------------------
-- Chat Message Type
------------------------------------------------------------

data ChatMessageType
  = ChatMessageType
  | DiceRollMessageType
  deriving (Generic, Eq)

instance ToJSON ChatMessageType where
  toEncoding ChatMessageType = string "ChatMessage"
  toEncoding DiceRollMessageType = string "DiceRollMessage"

instance FromJSON ChatMessageType where
  parseJSON (String "ChatMessage") = pure ChatMessageType
  parseJSON (String "DiceRollMessage") = pure DiceRollMessageType
  parseJSON _ = empty

instance Show ChatMessageType where
  show msg = case msg of
    ChatMessageType     -> "ChatMessage"
    DiceRollMessageType -> "DiceRollMessage"

instance FromField ChatMessageType where
  fromField f mdata = case mdata of
    Just "chat_message" -> pure ChatMessageType
    Just "dice_roll"    -> pure DiceRollMessageType
    Just _ -> returnError ConversionFailed f
              "Unrecognized value for ChatMessageType"
    _ -> returnError UnexpectedNull f "Null value for ChatMessageType"

instance ToField ChatMessageType where
  toField msg = case msg of
    ChatMessageType     -> Escape "chat_message"
    DiceRollMessageType -> Escape "dice_roll"

------------------------------------------------------------
-- Chat Message
------------------------------------------------------------

data ChatMessage
  = ChatMessage
    { _chatMessageTimestamp  :: UTCTime
    , _chatMessagePlayerId   :: PersonId
    , _chatMessagePlayerName :: Text
    , _chatMessageBody       :: Text
    }
  | DiceRollMessage
    { _chatMessageTimestamp  :: UTCTime
    , _chatMessagePlayerId   :: PersonId
    , _chatMessagePlayerName :: Text
    , _chatMessageDiceResult :: Value
    }  
  deriving (Generic)

instance ToJSON ChatMessage where
  toEncoding (ChatMessage time pid name body)
    = pairs
      (  "ctor"       .= ChatMessageType
      <> "timestamp"  .= (utcTimeToPOSIXSeconds time * 10^3)
      <> "playerId"   .= pid
      <> "playerName" .= name
      <> "body"       .= body
      )
  toEncoding (DiceRollMessage time pid name result)
    = pairs
      (  "ctor"       .= DiceRollMessageType
      <> "timestamp"  .= (utcTimeToPOSIXSeconds time * 10^3)
      <> "playerId"   .= pid
      <> "playerName" .= name
      <> "result"     .= result
      )


instance FromRow ChatMessage where
  fromRow = do
    ctor :: ChatMessageType <- field
    case ctor of
      ChatMessageType ->
        ChatMessage
         <$> field
         <*> field
         <*> field
         <*> ((flip fmap) field $ maybe
               (throw $ NotNullViolation
                 "ChatMessage body is null")
               id)
         <*  (field :: RowParser (Maybe Value))

      DiceRollMessageType ->
        DiceRollMessage
          <$> field
          <*> field
          <*> field
          <*  (field :: RowParser (Maybe Text))
          <*> ((flip fmap) field $ maybe
                (throw $ NotNullViolation
                  "ChatMessage dice_result is null")
                id)

------------------------------------------------------------
-- New Chat Message
------------------------------------------------------------

data NewChatMessage
  = NewChatMessage Text
  | NewDiceRollMessage Value

instance FromJSON NewChatMessage where
  parseJSON (Object v) = do
    ctor :: Text <- v .: "ctor"
    case ctor of
      "ChatMessage" -> NewChatMessage <$> v .: "body"
      "DiceRollMessage" -> NewDiceRollMessage <$> v .: "result"
      _ -> empty

------------------------------------------------------------
-- Access Level
------------------------------------------------------------

data AccessLevel
  = Player
  | GameMaster
  | Owner
  deriving (Generic, Eq)

instance ToJSON AccessLevel

instance Show AccessLevel where
  show acl = case acl of
    Player     -> "Player"
    GameMaster -> "Game Master"
    Owner      -> "Owner"

instance FromField AccessLevel where
  fromField f mdata = case mdata of
    Just "player"      -> pure Player
    Just "game_master" -> pure GameMaster
    Just "owner"       -> pure Owner
    Just _ -> returnError ConversionFailed f
              "Unrecognized value for AccessLevel"
    _ -> returnError UnexpectedNull f "Null value for AccessLevel"

instance ToField AccessLevel where
  toField acl = case acl of
    Player     -> Escape "player"
    GameMaster -> Escape "game_master"
    Owner      -> Escape "owner"

------------------------------------------------------------
-- Registration
------------------------------------------------------------

data Registration = Registration
  { _registrationUsername :: Text
  , _registrationEmail    :: Text
  , _registrationPassword :: Text
  } deriving (Show, Generic)

instance ToJSON Registration where
  toEncoding (Registration username email password)
    = pairs
      (  "username" .= username
      <> "email"    .= email
      <> "password" .= password
      )

instance FromJSON Registration where
  parseJSON (Object v)
    = Registration
      <$> v .: "username"
      <*> v .: "email"
      <*> v .: "password"
  
  parseJSON _ = empty

------------------------------------------------------------
-- Login
------------------------------------------------------------

data AuthenticationData = AuthenticationData
  { _authEmail    :: Text
  , _authPassword :: Text
  } deriving (Show, Generic)

instance ToJSON AuthenticationData where
  toEncoding (AuthenticationData email password)
    = pairs
      (  "email"    .= email
      <> "password" .= password
      )

instance FromJSON AuthenticationData where
  parseJSON (Object v)
    = AuthenticationData
      <$> v .: "email"
      <*> v .: "password"
  
  parseJSON _ = empty

------------------------------------------------------------
-- PersonId
------------------------------------------------------------

newtype PersonId = PersonId
  { unPersonId :: Int64
  } deriving newtype
      (FromField, ToField, FromJSON, ToJSON, Read, Eq, Ord)

instance FromHttpApiData PersonId where
  parseUrlPiece = fmap PersonId . parseUrlPiece

instance Show PersonId where
  show (PersonId id_) = show id_

instance FromRow PersonId where
  fromRow = PersonId
    <$> field

------------------------------------------------------------
-- Person
------------------------------------------------------------

data Person = Person
  { _personId       :: PersonId
  , _personUsername :: Text
  , _personAccess   :: AccessLevel
  , _personPresence :: Bool
  } deriving (Show, Generic)

instance ToJSON Person where
  toEncoding (Person (PersonId id_) username access presence)
    = pairs
      (  "id"       .= id_
      <> "username" .= username
      <> "access"   .= access
      <> "presence" .= if presence
                       then "online" :: Text
                       else "offline"
      )

instance FromRow Person where
  fromRow = (\a b c -> Person a b c False)
    <$> field
    <*> field
    <*> field

updatePresence :: Map PersonId UTCTime -> Person -> Person
updatePresence presence person =
  person { _personPresence = Map.member pid presence }
  where
    pid = _personId $ person

data PersonPresence = PersonPresence PersonId Bool
  deriving (Generic)

instance ToJSON PersonPresence where
  toEncoding (PersonPresence (PersonId id_) presence)
    = pairs
    (  "id" .= id_
    <> "presence" .= if presence
                     then "online" :: Text
                     else "offline"
    )

------------------------------------------------------------
-- GameId
------------------------------------------------------------

newtype GameId = GameId
  { unGameId :: UUID
  } deriving newtype (FromField, ToField)

instance FromRow GameId where
  fromRow = GameId
    <$> field

instance FromHttpApiData GameId where
  parseUrlPiece t =
    case UUID.fromText (stripPrefix t) of
      Nothing ->
        Left "Failed to convert text into uuid."
      Just uuid ->
        Right (GameId uuid)
    where
      stripPrefix
        = T.drop 1
        . T.dropWhile (/= '_')

instance ToJSON GameId where
  toJSON (GameId uuid) = toJSON ("game_" <> (show uuid))
  toEncoding (GameId uuid) = string ("game_" <> (show uuid))

instance Show GameId where
  show (GameId uuid) = "game_" <> show uuid

------------------------------------------------------------
-- Game
------------------------------------------------------------

data Game = Game
  { _gameId    :: GameId
  , _gameTitle :: Text
  } deriving (Show, Generic)

instance FromRow Game where
  fromRow = Game
    <$> field
    <*> field

instance ToJSON Game where
  toEncoding (Game id_ title)
    = pairs
      (  "id"    .= id_
      <> "title" .= title
      )

------------------------------------------------------------
-- NewGame
------------------------------------------------------------

data NewGame = NewGame
  { _newGameTitle :: Text
  , _newGameType :: Text
  } deriving (Show, Generic)

instance FromJSON NewGame where
  parseJSON (Object v)
    = NewGame
      <$> v .: "title"
      <*> v .: "gameType"

  parseJSON _ = empty

instance ToJSON NewGame where
  toEncoding (NewGame title gameType)
    = pairs
      (  "title"    .= title
      <> "gameType" .= gameType
      )

------------------------------------------------------------
-- Invite Code
------------------------------------------------------------

newtype InviteCode = InviteCode
  { unInviteCode :: Text
  } deriving newtype
      (Show, FromJSON, ToJSON, Read, Eq, Ord)

instance FromHttpApiData InviteCode where
  parseUrlPiece = fmap InviteCode . parseUrlPiece

