-- EXAMPLE 5: TENNIS LEAGUE POINTS SYSTEM (FROM AUGUST 2022/2023 EXAM)

CREATE OR ALTER PROCEDURE dbo.UpdatePoints
    @LSID INT,
    @PlayerID INT,
    @Points INT = 2  -- Default to 2 points for a win
AS
BEGIN
    SET NOCOUNT ON;
    
    BEGIN TRY
        -- Update player's points
        UPDATE LeagueScoresTBL
        SET Points = Points + @Points,
            UPD = GETDATE()
        WHERE LSID = @LSID
          AND PlayerID = @PlayerID;
        
        -- Insert if not exists
        IF @@ROWCOUNT = 0
        BEGIN
            DECLARE @LeagueID INT;
            
            -- Get the league ID for this LSID
            SELECT @LeagueID = LeagueID
            FROM LeagueScoresTBL
            WHERE LSID = @LSID;
            
            -- Insert new record
            INSERT INTO LeagueScoresTBL (LSID, LeagueID, PlayerID, Points, UPD)
            VALUES (@LSID, @LeagueID, @PlayerID, @Points, GETDATE());
        END
    END TRY
    BEGIN CATCH
        THROW;
    END CATCH
END;
GO

CREATE OR ALTER PROCEDURE dbo.MasterUpdateLeaguePoints
    @LSID INT,
    @Players PlayerList READONLY
AS
BEGIN
    SET NOCOUNT ON;
    
    -- Declare internal variables
    DECLARE @RetryCount INT = 0;
    DECLARE @MaxRetries INT = 3;
    DECLARE @MatchType VARCHAR(10);
    DECLARE @PlayerCount INT;
    DECLARE @ErrorMessage NVARCHAR(1000);
    
    -- Set isolation level for handling concurrent updates
    SET TRANSACTION ISOLATION LEVEL READ COMMITTED;
    -- Use row versioning to detect conflicts
    SET TRANSACTION ISOLATION LEVEL SNAPSHOT;
    
    /*
    ISOLATION LEVEL JUSTIFICATION:
    
    1. What concurrency issues this isolation level prevents:
       SNAPSHOT isolation prevents dirty reads, non-repeatable reads, and phantom reads
       without blocking other transactions. It works with row versioning to allow
       concurrent reads and writes without blocking.
       
    2. Example of issue in Tennis points system:
       Without SNAPSHOT, concurrent updates to the same player's points might block
       each other, causing delays. Also, if we read a player's membership dues but
       another transaction updates it before we finish, we'd make decisions on stale data.
       
    3. Effect on other transactions:
       Other transactions can continue to read and write data without being blocked by
       our transaction. If two transactions try to update the same row, the one that
       commits second will fail with a versioning conflict (which we handle with retries).
    */
    
    -- Count players to determine match type
    SELECT @PlayerCount = COUNT(*)
    FROM @Players;
    
    IF @PlayerCount = 1
        SET @MatchType = 'Singles';
    ELSE IF @PlayerCount = 2
        SET @MatchType = 'Doubles';
    ELSE
    BEGIN
        THROW 50001, 'Invalid number of players. Must be 1 (Singles) or 2 (Doubles).', 1;
    END
    
    -- Transaction retry loop
    WHILE @RetryCount < @MaxRetries
    BEGIN
        BEGIN TRY
            -- Begin transaction
            BEGIN TRANSACTION;
            
            -- BUSINESS RULE: Check membership dues
            IF @MatchType = 'Singles'
            BEGIN
                DECLARE @PlayerID INT;
                DECLARE @HasDues BIT = 0;
                
                -- Get the player ID from the list
                SELECT @PlayerID = PlayerID
                FROM @Players;
                
                -- Check if the player has membership dues
                SELECT @HasDues = 
                    CASE WHEN PlayerMemberShipDues IS NULL 
                         OR PlayerMemberShipDues <= 0 
                         THEN 1 ELSE 0 END
                FROM PlayerTBL
                WHERE PlayerID = @PlayerID;
                
                -- Reject update if dues not paid
                IF @HasDues = 1
                BEGIN
                    SET @ErrorMessage = 'Sorry membership is due for player ' + CAST(@PlayerID AS VARCHAR(10));
                    THROW 50002, @ErrorMessage, 1;
                END
            END
            ELSE IF @MatchType = 'Doubles'
            BEGIN
                -- For doubles, check both players
                                DECLARE @DuesList TABLE (PlayerID INT);
                                
                                -- Find players with unpaid dues
                                INSERT INTO @DuesList
                                SELECT p.PlayerID
                                FROM @Players p
                                JOIN PlayerTBL pt ON p.PlayerID = pt.PlayerID
                                WHERE pt.PlayerMemberShipDues IS NULL 
                                   OR pt.PlayerMemberShipDues <= 0;
                                
                                -- Count players with dues
                                DECLARE @DuesCount INT;
                                SELECT @DuesCount = COUNT(*) FROM @DuesList;
                                
                                -- If any players have dues, reject update
                                IF @DuesCount > 0
                                BEGIN
                                    DECLARE @PlayerList NVARCHAR(100) = '';
                                    
                                    -- Build list of player IDs with dues
                                    SELECT @PlayerList = @PlayerList + 
                                                         CASE WHEN @PlayerList = '' THEN '' ELSE ' and ' END + 
                                                         CAST(PlayerID AS VARCHAR(10))
                                    FROM @DuesList;
                                    
                                    SET @ErrorMessage = 'Sorry membership is due for players ' + @PlayerList;
                                    THROW 50003, @ErrorMessage, 1;
                                END
            END
            
            -- Update points for all players in the list
            DECLARE @CurPlayer INT;
            DECLARE PlayerCursor CURSOR FOR
                SELECT PlayerID FROM @Players;
            
            OPEN PlayerCursor;
            FETCH NEXT FROM PlayerCursor INTO @CurPlayer;
            
            WHILE @@FETCH_STATUS = 0
            BEGIN
                -- Call update points for each player
                EXEC UpdatePoints
                    @LSID = @LSID,
                    @PlayerID = @CurPlayer,
                    @Points = 2;  -- Award 2 points for a win
                
                FETCH NEXT FROM PlayerCursor INTO @CurPlayer;
            END
            
            CLOSE PlayerCursor;
            DEALLOCATE PlayerCursor;
            
            -- Commit transaction
            COMMIT TRANSACTION;
            
            -- Return success
            PRINT 'League points updated successfully for ' + @MatchType + ' match.';
            RETURN 0;
        END TRY
        BEGIN CATCH
            -- Rollback on error
            IF @@TRANCOUNT > 0
                ROLLBACK TRANSACTION;
            
            -- Clean up cursor if open
            IF CURSOR_STATUS('local', 'PlayerCursor') >= 0
            BEGIN
                CLOSE PlayerCursor;
                DEALLOCATE PlayerCursor;
            END
            
            -- Check for update conflict (snapshot isolation conflict)
            IF ERROR_NUMBER() IN (3960, 3961) -- Snapshot isolation conflict errors
            BEGIN
                SET @RetryCount = @RetryCount + 1;
                
                IF @RetryCount >= @MaxRetries
                BEGIN
                    THROW 50004, 'Transaction failed due to update conflicts after maximum retry attempts. Please resubmit the update.', 1;
                END
                
                -- Wait before retry
                WAITFOR DELAY '00:00:0' + CAST(@RetryCount AS VARCHAR(1));
                CONTINUE;
            END
            ELSE
            BEGIN
                -- Rethrow other errors
                THROW;
            END
        END CATCH
        
        -- Break loop on success
        BREAK;
    END
END;
GO