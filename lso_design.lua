-- Large Stack Object (LSO) Design
-- (March 4, 2013)
--
-- ======================================================================
-- Functions Supported
-- (*) stackCreate: Create the LSO structure in the chosen topRec bin
-- (*) stackPush: Push a user value (AS_VAL) onto the stack
-- (*) stackPeek: Read N values from the stack, in LIFO order
-- (*) stackTrim: Release all but the top N values.
-- ==> stackPush and stackPeek() functions each have the option of passing
-- in a Transformation/Filter UDF that modify values before storage or
-- modify and filter values during retrieval.
-- (*) stackPushWithUDF: Push a user value (AS_VAL) onto the stack, 
--     calling the supplied UDF on the value FIRST to transform it before
--     storing it on the stack.
-- (*) stackPeekWithUDF: Retrieve N values from the stack, and for each
--     value, apply the transformation/filter UDF to the value before
--     adding it to the result list.  If the value doesn't pass the
--     filter, the filter returns nil, and thus it would not be added
--     to the result list.
-- ======================================================================
-- LSO Design and Type Comments:
--
-- The LSO value is a new "particle type" that exists ONLY on the server.
-- It is a complex type (it includes infrastructure that is used by
-- server storage), so it can only be viewed or manipulated by Lua and C
-- functions on the server.  It is represented by a Lua MAP object that
-- comprises control information, a directory of records (for "warm data")
-- and a "Cold List Head" ptr to a linked list of directory structures
-- that each point to the records that hold the actual data values.
--
-- |||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||
-- Visual Depiction
-- |||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||
-- In a user record, the bin holding the Large Stack Object (LSO) is
-- referred to as an "LSO" bin. The overhead of the LSO value is 
-- (*) LSO Control Info (~70 bytes)
-- (*) LSO Hot Cache: List of data entries (on the order of 100)
-- (*) LSO Warm Directory: List of Aerospike Record digests:
--     100 digests(250 bytes)
-- (*) LSO Cold Directory Head (digest of Head plus count) (30 bytes)
-- (*) Total LSO Record overhead is on the order of 350 bytes
-- NOTES:
-- (*) In the Hot Cache, the data items are stored directly in the
--     cache list (regardless of whether they are bytes or other as_val types)
-- (*) In the Warm Dir List, the list contains aerospike digests of the
--     LSO Data Records (LDRs) that hold the Warm Data.  The LDRs are
--     opened (using the digest), then read/written, then closed/updated.
-- (*) The Cold Dir Head holds the Aerospike Record digest of a record that
--     holds a linked list of cold directories.  Each cold directory holds
--     a list of digests that are the cold LSO Data Records.
-- (*) The Warm and Cold LSO Data Records use the same format -- so they
--     simply transfer from the warm list to the cold list by moving the
--     corresponding digest from the warm list to the cold list.
-- (*) Record types used in this design:
-- (1) There is the main record that contains the LSO bin (LSO Head)
-- (2) There are LSO Data "Chunk" Records (both Warm and Cold)
--     ==> Warm and Cold LSO Data Records have the same format:
--         They both hold User Stack Data.
-- (3) There are Chunk Directory Records (used in the cold list)
--
-- (*) How it all connects together....
-- (+) The main record points to:
--     - Warm Data Chunk Records (these records hold stack data)
--     - Cold Data Directory Records (these records hold ptrs to Cold Chunks)
--
-- (*) We may have to add some auxilliary information that will help
--     pick up the pieces in the event of a network/replica problem, where
--     some things have fallen on the floor.  There might be some "shadow
--     values" in there that show old/new values -- like when we install
--     a new cold dir head, and other things.  TBD
--
-- (*)
--
--
-- +-----+-----+-----+-----+----------------------------------------+
-- |User |User |o o o|LSO  |                                        |
-- |Bin 1|Bin 2|o o o|Bin 1|                                        |
-- +-----+-----+-----+-----+----------------------------------------+
--                  /       \                                       
--   ================================================================
--     LSO Map                                              
--     +-------------------+                                 
--     | LSO Control Info  |  About 20 different values kept in Ctrl Info
--     +----------------++++++++++
--     | Hot Entry Cache|||||||||| Entries are stored directly in the Record
--     +----------------++++++++++
--     | LSO Warm Dir List |-+                                     
--     +-------------------+ |                                   
--   +-| LSO Cold Dir Head | |                                   
--   | +-------------------+ |                                   
--   |          +------------+
--   |          |                                                
--   |          V (Warm Directory)              Warm Data(WD)
--   |      +---------+                          Chunk Rec 1
--   |      |Digest 1 |+----------------------->+--------+
--   |      |---------|              WD Chunk 2 |Entry 1 |
--   |      |Digest 2 |+------------>+--------+ |Entry 2 |
--   |      +---------+              |Entry 1 | |   o    |
--   |      | o o o   |              |Entry 2 | |   o    |
--   |      |---------|  WD Chunk N  |   o    | |   o    |
--   |      |Digest N |+->+--------+ |   o    | |Entry n |
--   |      +---------+   |Entry 1 | |   o    | +--------+
--   |                    |Entry 2 | |Entry n |
--   |                    |   o    | +--------+
--   |                    |   o    |
--   |                    |   o    |
--   |                    |Entry n |
--   |                    +--------+
--   |                          +-----+->+-----+->+-----+ ->+-----+
--   +----------------------->  |Rec  |  |Rec  |  |Rec  | o |Rec  |
--    The cold dir is a linked  |Chunk|  |Chunk|  |Chunk| o |Chunk|
--    list of dir pages that    |Dir  |  |Dir  |  |Rec  | o |Dir  |
--    point to LSO Data Records +-----+  +-----+  +-----+   +-----+
--    that hold the actual cold  ||...|   ||...|   ||...|    ||...|
--    data (cold chunks).        ||   V   ||   V   ||   V    ||   V
--                               ||   +--+||   +--+||   +--+ ||   +--+
--    As "Warm Data" ages out    ||   |Cn|||   |Cn|||   |Cn| ||   |Cn|
--    of the Warm Dir List, the  |V   +--+|V   +--+|V   +--+ |V   +--+
--    LDRs transfer out of the   |+--+    |+--+    |+--+     |+--+
--    Warm Directory and into    ||C2|    ||C2|    ||C2|     ||C2|
--    the cold directory.         V+--+    V+--+    V+--+     V+--+
--                               +--+     +--+     +--+      +--+
--    The Warm and Cold LDRs     |C1|     |C1|     |C1|      |C1|
--    have identical structure.  +--+     +--+     +--+      +--+
--                                A        A        A         A    
--                                |        |        |         |
--           [Cold Data Chunks]---+--------+--------+---------+
--
--
-- The "Hot Entry Cache" is the true "Top of Stack", holding roughly the
-- top 50 to 100 values.  The next level of storage is found in the first
-- Warm dir list (the last Chunk in the list).  Since we process stack
-- operations in LIFO order, but manage them physically as a list
-- (append to the end), we basically read the pieces in top down order,
-- but we read the CONTENTS of those pieces backwards.  It is too expensive
-- to "prepend" to a list -- and we are smart enough to figure out how to
-- read an individual page list bottom up (in reverse append order).
--
-- We don't "age" the individual entries out one at a time as the Hot Cache
-- overflows -- we instead take a group at a time (specified by the
-- HotCacheTransferAmount), which opens up a block empty spots. Notice that
-- the transfer amount is a tuneable parameter -- for heavy reads, we would
-- want MORE data in the cache, and for heavy writes we would want less.
--
-- If we generally pick half (100 entries total, and then transfer 50 at
-- a time when the cache fills up), then half the time the insers will affect
-- ONLY the Top (LSO) record -- so we'll have only one Read, One Write 
-- operation for a stack push.  1 out of 50 will have the double read,
-- double write, and 1 out of a thousand (or so) will have additional
-- IO's depending on the state of the Warm/Cold lists.
--
-- NOTE: Design, V3.  For really cold data -- things out beyond 50,000
-- elements, it might make sense to just push those out to a real disk
-- based file (to which we could just append -- and read in reverse order).
-- If we ever need to read the whole stack, we can afford
-- the time and effort to read the file (it is an unlikely event).  The
-- issue here is that we probably have to teach Aerospike how to transfer
-- (and replicate) files as well as records.
-- |||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||
-- || LSO Bin CONTENTS  ||||||||||||||||||||||||||||||||||||||||||||||||||
-- |||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||
-- ======================================================================
-- In the LSO bin (named by the user), there is a Map object:
-- accessed, as follows:
--  local lsoMap = topRec[lsoBinName]; -- The main LSO map
-- The Contents of the map (with values, is as follows:
-- (Note: The arglist values show which values are configured by the user:
--
-- The LSO Map -- with Default Values
-- General Parms:
lsoMap.ItemCount = 0;     -- A count of all items in the stack
lsoMap.DesignVersion = 1; -- Current version of the code
lsoMap.Magic = "MAGIC";   -- Used to verify we have a valid map
lsoMap.BinName = lsoBinName; -- The name of the Bin for this LSO in TopRec
lsoMap.NameSpace = "test"; -- Default NS Name -- to be overridden by user
lsoMap.Set = "set";       -- Default Set Name -- to be overridden by user
lsoMap.PageMode = "List"; -- "List" or "Binary":
-- LSO Data Record Chunk Settings
lsoMap.LdrEntryCountMax = 200;  -- Max # of items in a Data Chunk (List Mode)
lsoMap.LdrByteEntrySize = 20;  -- Byte size of a fixed size Byte Entry
lsoMap.LdrByteCountMax = 2000; -- Max # of BYTES in a Data Chunk (binary mode)
-- Hot Cache Settings
lsoMap.HotCacheList = list();
lsoMap.HotCacheItemCount = 0; -- Number of elements in the Top Cache
lsoMap.HotCacheMax = 200; -- Max Number for the cache -- when we transfer
lsoMap.HotCacheTransfer = 100; -- How much to Transfer at a time.
-- Warm Cache Settings
lsoMap.WarmTopFull = 0; -- 1  when the top chunk is full (for the next write)
lsoMap.WarmCacheList = list();   -- Define a new list for the Warm Stuff
lsoMap.WarmChunkCount = 0; -- Number of Warm Data Record Chunks
lsoMap.WarmCacheDirMax = 1000; -- Number of Warm Data Record Chunks
lsoMap.WarmChunkTransfer = 10; -- Number of Warm Data Record Chunks
lsoMap.WarmTopChunkEntryCount = 0; -- Count of entries in top warm chunk
lsoMap.WarmTopChunkByteCount = 0; -- Count of bytes used in top warm Chunk
-- Cold Cache Settings
lsoMap.ColdChunkCount = 0; -- Number of Cold Data Record Chunks
lsoMap.ColdDirCount = 0; -- Number of Cold Data Record DIRECTORY Chunks
lsoMap.ColdListHead  = 0;   -- Nothing here yet
lsoMap.ColdCacheDirMax = 100;  -- Should be a setable parm

-- ======================================================================
--
-- |||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||
-- || LSO Data Records (LDR), also known as "chunks"  ||||||||||||||||||||
-- |||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||
--
-- Chunks hold the actual entries. Each LSO Data Record (LDR) holds a small
-- amount of control information and a list.  A LDR will have three bins:
-- (1) The Control Bin (a Map with the various control data)
-- (2) The List bin -- where we hold "list entries"
-- (3) The Binary Bin -- where we hold compacted binary entries (just the
--     as bytes values)
-- (*) Note that ONLY ONE of the two content bins will be used.  We will be
--     in either LIST MODE (bin 2) or BINARY MODE (bin 3)
-- ==> 'LdrControlBin' Contents (a Map)
--    + 'ParentDigest' (to track who we belong to: Lso if warm, ColdDir if cold
--    + 'Page Type' (Warm Data, Code Data or Dir)
--    + 'Page Mode' (List data or Binary Data)
--    + 'Digest' (the digest that we would use to find this chunk)
--    - 'EntryMax':  Kept in the main control: topRec[lsoBinName]:
--                   0 means Variable, so use BYTE MAX, not Entry Count
--    - 'Entry Size': Kept in the main control: topRec[lsoBinName]:
--                   0 means Variable size, >0 is fixed size
--    - 'Byte Max':   Kept in the main control: topRec[lsoBinName]:
--                   0 means fixed size, use ENTRY MAX, not byte max
--    + 'Bytes Used': Number of bytes used, but ONLY when in "byte mode"
--    + 'Design Version': Decided by the code:  DV starts at 1.0
--    + 'Log Info':(Log Sequence Number, for when we log updates)
--
--  ==> 'LdrListBin' Contents (A List holding entries)
--  ==> 'LdrBinaryBin' Contents (A single BYTE value, holding packed entries)
--    + Note that the Size and Count fields are needed for BINARY and are
--      kept in the control bin (EntrySize, ItemCount)
--
--    -- Entry List (Holds entry and, implicitly, Entry Count)
--
-- |||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||
-- || LSO Directory Records (LDIR) |||||||||||||||||||||||||||||||||||||||
-- |||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||
--
-- A Directory Record (Cold List Only) contains the following:
-- (1) 'ControlBin': (map with control data)
--     - Page Type (dir)
--     - This Record Digest
--     - List Mode (bin 2, Lua List) or (bin 3, BINARY COMPACT LIST)
--     - Entry Max
--     - Byte Max
--     - Entry Max
-- (2) 'DigestListBin': (list of digests of Cold LDRs)
-- (3) 'DigestBnryBin': BINARY list of digests (only one type of list is
--                      used: either the List bin or Binary bin)
--
-- ======================================================================
-- Aerospike Calls:
-- newRec = aerospike:crec_create( topRec )
-- newRec = aerospike:crec_open( record, digest)
-- status = aerospike:crec_update( record, newRec )
-- status = aerospike:crec_close( record, newRec )
-- digest = record.digest( newRec )
-- ======================================================================

-- <EOF> -- <EOF> -- <EOF> -- <EOF> -- <EOF> -- <EOF> -- <EOF> -- <EOF> --
