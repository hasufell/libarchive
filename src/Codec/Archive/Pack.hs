module Codec.Archive.Pack ( entriesToFile
                          , entriesToFileZip
                          , entriesToFile7Zip
                          , entriesToBS
                          , entriesToBSzip
                          , entriesToBS7zip
                          , packEntries
                          , noFail
                          , packToFile
                          , packToFileZip
                          , packToFile7Zip
                          ) where

import           Codec.Archive.Foreign
import           Codec.Archive.Monad
import           Codec.Archive.Pack.Common
import           Codec.Archive.Types
import           Control.Monad             (void)
import           Control.Monad.IO.Class    (MonadIO (..))
import           Data.ByteString           (packCStringLen)
import qualified Data.ByteString           as BS
import           Data.Coerce               (coerce)
import           Data.Foldable             (sequenceA_, traverse_)
import           Data.Semigroup            (Sum (..))
import           Foreign.C.String
import           Foreign.C.Types           (CLLong (..), CLong (..))
import           Foreign.ForeignPtr        (ForeignPtr)
import           Foreign.Ptr               (Ptr)
import           System.IO.Unsafe          (unsafePerformIO)

maybeDo :: Applicative f => Maybe (f ()) -> f ()
maybeDo = sequenceA_

contentAdd :: EntryContent -> ArchivePtr -> Ptr ArchiveEntry -> ArchiveM ()
contentAdd (NormalFile contents) a entry = do
    liftIO $ archiveEntrySetFiletype entry FtRegular
    liftIO $ archiveEntrySetSize entry (fromIntegral (BS.length contents))
    handle $ archiveWriteHeader a entry
    useAsCStringLenArchiveM contents $ \(buff, sz) ->
        liftIO $ void $ archiveWriteData a buff (fromIntegral sz)
contentAdd Directory a entry = do
    liftIO $ archiveEntrySetFiletype entry FtDirectory
    handle $ archiveWriteHeader a entry
contentAdd (Symlink fp) a entry = do
    liftIO $ archiveEntrySetFiletype entry FtLink
    liftIO $ withCString fp $ \fpc ->
        archiveEntrySetSymlink entry fpc
    handle $ archiveWriteHeader a entry

withMaybeCString :: Maybe String -> (Maybe CString -> IO a) -> IO a
withMaybeCString (Just x) f = withCString x (f . Just)
withMaybeCString Nothing f  = f Nothing

setOwnership :: Ownership -> Ptr ArchiveEntry -> IO ()
setOwnership (Ownership uname gname uid gid) entry =
    withMaybeCString uname $ \unameC ->
    withMaybeCString gname $ \gnameC ->
    traverse_ maybeDo
        [ archiveEntrySetUname entry <$> unameC
        , archiveEntrySetGname entry <$> gnameC
        , Just (archiveEntrySetUid entry (coerce uid))
        , Just (archiveEntrySetGid entry (coerce gid))
        ]

setTime :: ModTime -> Ptr ArchiveEntry -> IO ()
setTime (time', nsec) entry = archiveEntrySetMtime entry time' nsec

packEntries :: (Foldable t) => ArchivePtr -> t Entry -> ArchiveM ()
packEntries a = traverse_ (archiveEntryAdd a)

-- Get a number of bytes appropriate for creating the archive.
entriesSz :: (Foldable t, Integral a) => t Entry -> a
entriesSz = getSum . foldMap (Sum . entrySz)
    where entrySz e = 512 + 512 * (contentSz (content e) `div` 512 + 1)
          contentSz (NormalFile str) = fromIntegral $ BS.length str
          contentSz Directory        = 0
          contentSz (Symlink fp)     = fromIntegral $ length fp

-- | Returns a 'BS.ByteString' containing a tar archive with the 'Entry's
--
-- @since 1.0.0.0
entriesToBS :: Foldable t => t Entry -> BS.ByteString
entriesToBS = unsafePerformIO . noFail . entriesToBSGeneral archiveWriteSetFormatPaxRestricted
{-# NOINLINE entriesToBS #-}

-- | Returns a 'BS.ByteString' containing a @.7z@ archive with the 'Entry's
--
-- @since 1.0.0.0
entriesToBS7zip :: Foldable t => t Entry -> BS.ByteString
entriesToBS7zip = unsafePerformIO . noFail . entriesToBSGeneral archiveWriteSetFormat7zip
{-# NOINLINE entriesToBS7zip #-}

-- | Returns a 'BS.ByteString' containing a zip archive with the 'Entry's
--
-- @since 1.0.0.0
entriesToBSzip :: Foldable t => t Entry -> BS.ByteString
entriesToBSzip = unsafePerformIO . noFail . entriesToBSGeneral archiveWriteSetFormatZip
{-# NOINLINE entriesToBSzip #-}

-- This is for things we don't think will fail. When making a 'BS.ByteString'
-- from a bunch of 'Entry's, for instance, we don't anticipate any errors
noFail :: ArchiveM a -> IO a
noFail act = do
    res <- runArchiveM act
    case res of
        Right x -> pure x
        Left _  -> error "Should not fail."

-- | Internal function to be used with 'archive_write_set_format_pax' etc.
entriesToBSGeneral :: (Foldable t) => (ArchivePtr -> IO ArchiveResult) -> t Entry -> ArchiveM BS.ByteString
entriesToBSGeneral modifier hsEntries' = do
    a <- liftIO archiveWriteNew
    ignore $ modifier a
    allocaBytesArchiveM bufSize $ \buffer -> do
        (err, usedSz) <- liftIO $ archiveWriteOpenMemory a buffer bufSize
        handle (pure err)
        packEntries a hsEntries'
        handle $ archiveWriteClose a
        res <- liftIO $ curry packCStringLen buffer (fromIntegral usedSz)
        ignore $ archiveFree a
        pure res

    where bufSize :: Integral a => a
          bufSize = entriesSz hsEntries'

filePacker :: (Traversable t) => (FilePath -> t Entry -> ArchiveM ()) -> FilePath -> t FilePath -> ArchiveM ()
filePacker f tar fps = f tar =<< liftIO (traverse mkEntry fps)

-- | @since 2.0.0.0
packToFile :: Traversable t
           => FilePath -- ^ @.tar@ archive to be created
           -> t FilePath -- ^ Files to include
           -> ArchiveM ()
packToFile = filePacker entriesToFile

-- | @since 2.0.0.0
packToFileZip :: Traversable t
              => FilePath
              -> t FilePath
              -> ArchiveM ()
packToFileZip = filePacker entriesToFileZip

-- | @since 2.0.0.0
packToFile7Zip :: Traversable t
               => FilePath
               -> t FilePath
               -> ArchiveM ()
packToFile7Zip = filePacker entriesToFile7Zip

-- | Write some entries to a file, creating a tar archive. This is more
-- efficient than
--
-- @
-- BS.writeFile "file.tar" (entriesToBS entries)
-- @
--
-- @since 1.0.0.0
entriesToFile :: Foldable t => FilePath -> t Entry -> ArchiveM ()
entriesToFile = entriesToFileGeneral archiveWriteSetFormatPaxRestricted
-- this is the recommended format; it is a tar archive

-- | Write some entries to a file, creating a zip archive.
--
-- @since 1.0.0.0
entriesToFileZip :: Foldable t => FilePath -> t Entry -> ArchiveM ()
entriesToFileZip = entriesToFileGeneral archiveWriteSetFormatZip

-- | Write some entries to a file, creating a @.7z@ archive.
--
-- @since 1.0.0.0
entriesToFile7Zip :: Foldable t => FilePath -> t Entry -> ArchiveM ()
entriesToFile7Zip = entriesToFileGeneral archiveWriteSetFormat7zip

entriesToFileGeneral :: Foldable t => (ArchivePtr -> IO ArchiveResult) -> FilePath -> t Entry -> ArchiveM ()
entriesToFileGeneral modifier fp hsEntries' = do
    a <- liftIO archiveWriteNew
    ignore $ modifier a
    withCStringArchiveM fp $ \fpc ->
        handle $ archiveWriteOpenFilename a fpc
    packEntries a hsEntries'

withArchiveEntry :: MonadIO m => (Ptr ArchiveEntry -> m a) -> m a
withArchiveEntry fact = do
    entry <- liftIO archiveEntryNew
    res <- fact entry
    liftIO $ archiveEntryFree entry
    pure res

archiveEntryAdd :: ArchivePtr -> Entry -> ArchiveM ()
archiveEntryAdd a (Entry fp contents perms owner mtime) =
    withArchiveEntry $ \entry -> do
        liftIO $ withCString fp $ \fpc ->
            archiveEntrySetPathname entry fpc
        liftIO $ archiveEntrySetPerm entry perms
        liftIO $ setOwnership owner entry
        liftIO $ maybeDo (setTime <$> mtime <*> pure entry)
        contentAdd contents a entry
