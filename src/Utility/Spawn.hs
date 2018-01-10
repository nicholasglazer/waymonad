{-
waymonad A wayland compositor in the spirit of xmonad
Copyright (C) 2017  Markus Ongyerth

This library is free software; you can redistribute it and/or
modify it under the terms of the GNU Lesser General Public
License as published by the Free Software Foundation; either
version 2.1 of the License, or (at your option) any later version.

This library is distributed in the hope that it will be useful,
but WITHOUT ANY WARRANTY; without even the implied warranty of
MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
Lesser General Public License for more details.

You should have received a copy of the GNU Lesser General Public
License along with this library; if not, write to the Free Software
Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA  02110-1301  USA

Reach us at https://github.com/ongy/waymonad
-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
module Utility.Spawn
    ( spawn

    , spawnNamed
    , manageNamed
    , namedSpawner

    , spawnOn
    , manageSpawnOn
    , onSpawner

    , getClientName

    , Spawner (..)
    , spawnManaged
    )
where

import Control.Monad (void)
import Control.Monad.IO.Class (MonadIO, liftIO)
import Data.IntMap (IntMap)
import Data.Text (Text)
import Data.Typeable (Typeable)
import Network.Socket
    ( Socket
    , socketPair
    , Family(AF_UNIX)
    , SocketType(Stream)
    , fdSocket
    , close
    )
import System.Posix.Env (putEnv)
import System.Posix.Types (Fd (..))
import System.Posix.Process (forkProcess, executeFile)
import System.Process (spawnCommand)

import Graphics.Wayland.Server (Client (..), clientCreate)
import Graphics.Wayland.Server.Client (addDestroyListener)

import Managehook (Managehook, query, liftWay, InsertAction (InsertInto))
import Utility (whenJust, ptrToInt)
import View (getViewClient)
import ViewSet (WSTag)
import Waymonad (Way, setCallback, WayLoggers(loggerSpawner))
import Waymonad.Extensible (ExtensionClass (..))
import WayUtil
    ( getEState
    , modifyEState
    , getDisplay
    )
import WayUtil.Log (logPutText, LogPriority (..))

import qualified Data.IntMap.Strict as IM
import qualified Data.Text as T

-- The most simple generic spawn function
spawn :: (MonadIO m) => String -> m ()
spawn = void . liftIO . spawnCommand

newtype WSMap a = WSMap { unWM :: IntMap a }
    deriving (Show, Eq, Monoid)

instance Typeable a => ExtensionClass (WSMap a) where
    initialValue = mempty

newtype NameMap = NameMap { unNM :: IntMap Text }
    deriving (Show, Eq, Monoid)

instance ExtensionClass NameMap where
    initialValue = mempty

spawnClient :: Socket -> Fd -> String -> [String] -> IO ()
spawnClient socket fd cmd args = do
    close socket
    putEnv $ "WAYLAND_SOCKET=" ++ show fd
    executeFile cmd True args Nothing

clientToInt :: Client -> Int
clientToInt (Client c) = ptrToInt c

spawnNamed :: Text -> String -> [String] -> Way vs a ()
spawnNamed = spawnManaged . pure . namedSpawner

namedSpawner :: Text -> Spawner vs a
namedSpawner name = Spawner
    { spawnAdd = \client -> modifyEState $ NameMap . IM.insert (clientToInt client) name . unNM
    , spawnRm = \client -> modifyEState $ NameMap . IM.delete (clientToInt client) . unNM
    }

getClientName :: Client -> Way vs a (Maybe Text)
getClientName c = IM.lookup (clientToInt c) . unNM <$> getEState

manageNamed :: Managehook vs a
manageNamed = do
    (Just c) <- getViewClient =<< query
    liftWay $ do
        nameM <- getClientName c
        whenJust nameM $ \name ->
            logPutText loggerSpawner Info $ "Client \"" `T.append` name `T.append` "\" just spawned"
    mempty

spawnOn :: WSTag a => a -> String -> [String] -> Way vs a ()
spawnOn = spawnManaged . pure . onSpawner

getClientWS :: Typeable a => Client -> Way vs a (Maybe a)
getClientWS c = IM.lookup (clientToInt c) . unWM <$> getEState

manageSpawnOn :: WSTag a => Managehook vs a
manageSpawnOn = do
    (Just c) <- getViewClient =<< query
    wsM <- liftWay $ getClientWS c
    case wsM of
        Nothing -> mempty
        Just ws -> pure $ InsertInto ws

onSpawner :: forall vs a. WSTag a => a -> Spawner vs a
onSpawner ws = Spawner
    { spawnAdd = \client -> modifyEState $ WSMap . IM.insert (clientToInt client) ws . unWM
    , spawnRm = \client -> modifyEState $
        (WSMap :: IntMap a -> WSMap a) . IM.delete (clientToInt client) . unWM
    }

data Spawner vs a = Spawner
    { spawnAdd :: Client -> Way vs a ()
    , spawnRm :: Client -> Way vs a ()
    }

spawnManaged
    :: forall vs a.
       [Spawner vs a]
    -> String
    -> [String]
    -> Way vs a ()
spawnManaged spawners cmd args = do
    (cSock, sSock) <- liftIO $ socketPair AF_UNIX Stream 0
    void . liftIO . forkProcess $ spawnClient sSock (Fd $ fdSocket cSock) cmd args

    liftIO $ close cSock
    let cFd = fdSocket sSock
    dsp <- getDisplay
    clientM <- liftIO $ clientCreate dsp (Fd cFd)
    whenJust clientM $ \client -> do
        addFun client
        setCallback rmFun (addDestroyListener client)
    where   addFun :: Client -> Way vs a ()
            addFun client = void . traverse ($ client) $ map spawnAdd spawners
            rmFun :: Client -> Way vs a ()
            rmFun client = void . traverse ($ client) $ map spawnRm spawners
