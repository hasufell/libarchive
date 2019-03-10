module Codec.Archive.Pack ( packEntries
                          , entriesToFile
                          ) where

import           Codec.Archive.Foreign
import           Codec.Archive.Types
import           Control.Monad         (void)
import           Data.ByteString       (useAsCStringLen)
import           Data.Foldable         (traverse_)
import           Foreign.C.String
import           Foreign.Ptr           (Ptr)

contentAdd :: EntryContent -> Ptr Archive -> Ptr ArchiveEntry -> IO ()
contentAdd (NormalFile contents) a entry = do
    archive_entry_set_filetype entry regular
    void $ archive_write_header a entry
    useAsCStringLen contents $ \(buff, sz) ->
        void $ archive_write_data a buff (fromIntegral sz)
contentAdd Directory a entry = do
    archive_entry_set_filetype entry directory
    void $ archive_write_header a entry
contentAdd (Symlink fp) a entry = do
    archive_entry_set_filetype entry symlink
    withCString fp $ \fpc ->
        archive_entry_set_symlink entry fpc
    void $ archive_write_header a entry

setOwnership :: Ownership -> Ptr ArchiveEntry -> IO ()
setOwnership (Ownership uname gname uid gid) entry =
    withCString uname $ \unameC ->
    withCString gname $ \gnameC ->
    sequence_
        [ archive_entry_set_uname entry unameC
        , archive_entry_set_gname entry gnameC
        , archive_entry_set_uid entry uid
        , archive_entry_set_gid entry gid
        ]

setTime :: ModTime -> Ptr ArchiveEntry -> IO ()
setTime (time', nsec) entry = archive_entry_set_mtime entry time' nsec

packEntries :: (Foldable t) => Ptr Archive -> t Entry -> IO ()
packEntries a = traverse_ (archiveEntryAdd a)

entriesToFile :: Foldable t => FilePath -> t Entry -> IO ()
entriesToFile fp hsEntries' = do
    a <- archive_write_new
    -- this is the recommended format; it is a tar archive
    void $ archive_write_set_format_pax_restricted a
    withCString fp $ \fpc ->
        void $ archive_write_open_filename a fpc
    packEntries a hsEntries'
    void $ archive_write_free a

withArchiveEntry :: (Ptr ArchiveEntry -> IO a) -> IO a
withArchiveEntry fact = do
    entry <- archive_entry_new
    res <- fact entry
    archive_entry_free entry
    pure res

archiveEntryAdd :: Ptr Archive -> Entry -> IO ()
archiveEntryAdd a (Entry fp contents perms owner mtime) =
    withArchiveEntry $ \entry -> do
        withCString fp $ \fpc ->
            archive_entry_set_pathname entry fpc
        archive_entry_set_perm entry perms
        setOwnership owner entry
        setTime mtime entry
        contentAdd contents a entry
        pure ()