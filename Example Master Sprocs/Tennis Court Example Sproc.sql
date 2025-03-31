-- EXAMPLE 4: TENNIS COURT BOOKING SYSTEM (FROM JUNE 2022/2023 EXAM)

CREATE OR ALTER PROCEDURE dbo.InsertBooking
    @ReservationNo VARCHAR(20),
    @BookingStartTime DATETIME,
    @BookingEndTime DATETIME,
    @CourtID INT,
    @BookingMadeBy INT,
    @NewBookingID INT OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    
    BEGIN TRY
        -- Insert booking record
        INSERT INTO BookingTBL (
            ReservationNo,
            BookingStartTime,
            BookingEndTime,
            CourtID,
            BookingMadeBy
        )
        VALUES (
            @ReservationNo,
            @BookingStartTime,
            @BookingEndTime,
            @CourtID,
            @BookingMadeBy
        );
        
        -- Get new booking ID
        SET @NewBookingID = SCOPE_IDENTITY();
    END TRY
    BEGIN CATCH
        THROW;
    END CATCH
END;
GO

CREATE OR ALTER PROCEDURE dbo.InsertReservation
    @BookingList BookingList READONLY
AS
BEGIN
    SET NOCOUNT ON;
    
    BEGIN TRY
        -- Insert reservations for players
        INSERT INTO ReservationTBL (BookingID, PlayerID)
        SELECT BookingID, PlayerID
        FROM @BookingList;
    END TRY
    BEGIN CATCH
        THROW;
    END CATCH
END;
GO

CREATE OR ALTER PROCEDURE dbo.UpdateEarning
    @CourtID INT,
    @PlayerCount INT
AS
BEGIN
    SET NOCOUNT ON;
    
    DECLARE @CourtCost DECIMAL(10,2);
    
    BEGIN TRY
        -- Get court cost
        SELECT @CourtCost = CourtCost
        FROM CourtsTBL
        WHERE CourtID = @CourtID;
        
        -- Update court earnings
        UPDATE CourtsTBL
        SET CourtEarnings = CourtEarnings + (@CourtCost * @PlayerCount)
        WHERE CourtID = @CourtID;
    END TRY
    BEGIN CATCH
        THROW;
    END CATCH
END;
GO

CREATE OR ALTER PROCEDURE dbo.MasterCourtBooking
    @BookingMadeBy INT,
    @BookingStartTime DATETIME,
    @BookingEndTime DATETIME,
    @CourtID INT,
    @Players PlayerList READONLY
AS
BEGIN
    SET NOCOUNT ON;
    
    -- Declare internal variables
    DECLARE @RetryCount INT = 0;
    DECLARE @MaxRetries INT = 3;
    DECLARE @ReservationNo VARCHAR(20);
    DECLARE @NewBookingID INT;
    DECLARE @PlayerCount INT;
    
    -- Set isolation level
    SET TRANSACTION ISOLATION LEVEL READ COMMITTED;
    
    /*
    ISOLATION LEVEL JUSTIFICATION:
    
    1. What concurrency issues this isolation level prevents:
       READ COMMITTED prevents dirty reads. This ensures we only see committed data
       and won't make decisions based on uncommitted changes.
       
    2. Example of issue in Tennis booking:
       Without READ COMMITTED, we might read uncommitted court earnings or booking data
       that could later be rolled back, causing incorrect calculations or double bookings.
       
    3. Effect on other transactions:
       Other transactions can still modify data after we've read it but before we commit.
       This provides good performance while ensuring basic data integrity.
    */
    
    -- Generate reservation number
    SET @ReservationNo = 'RES-' + CONVERT(VARCHAR(8), GETDATE(), 112) + '-' + 
                         RIGHT('0000' + CAST(@CourtID AS VARCHAR(4)), 4);
    
    -- Count players
    SELECT @PlayerCount = COUNT(*)
    FROM @Players;
    
    -- Transaction retry loop
    WHILE @RetryCount < @MaxRetries
    BEGIN
        BEGIN TRY
            -- Begin transaction
            BEGIN TRANSACTION;
            
            -- BUSINESS RULE 1: Check for double booking
            IF EXISTS (
                SELECT 1
                FROM BookingTBL
                WHERE CourtID = @CourtID
                  AND (
                    (@BookingStartTime < BookingEndTime AND @BookingEndTime > BookingStartTime)
                  )
            )
            BEGIN
                -- Court already booked for this time slot
                THROW 50001, 'Sorry court is already booked for this slot', 1;
            END
            
            -- Insert booking record
            EXEC InsertBooking
                @ReservationNo = @ReservationNo,
                @BookingStartTime = @BookingStartTime,
                @BookingEndTime = @BookingEndTime,
                @CourtID = @CourtID,
                @BookingMadeBy = @BookingMadeBy,
                @NewBookingID = @NewBookingID OUTPUT;
            
            -- Create booking list for players
            DECLARE @BookingList BookingList;
            
            -- Add players to booking list
            INSERT INTO @BookingList (BookingID, PlayerID)
            SELECT @NewBookingID, PlayerID
            FROM @Players;
            
            -- Insert reservations
            EXEC InsertReservation
                @BookingList = @BookingList;
            
            -- BUSINESS RULE 2: Update court earnings
            EXEC UpdateEarning
                @CourtID = @CourtID,
                @PlayerCount = @PlayerCount;
            
            -- Commit transaction
            COMMIT TRANSACTION;
            
            -- Return success
            PRINT 'Court booking successful. Reservation number: ' + @ReservationNo;
            RETURN 0;
        END TRY
        BEGIN CATCH
            -- Rollback on error
            IF @@TRANCOUNT > 0
                ROLLBACK TRANSACTION;
            
            -- Check for deadlock
            IF ERROR_NUMBER() = 1205
            BEGIN
                SET @RetryCount = @RetryCount + 1;
                
                IF @RetryCount >= @MaxRetries
                BEGIN
                    THROW 50002, 'Transaction has been terminated because of high usage - please retry', 1;
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