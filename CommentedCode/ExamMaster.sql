CREATE OR ALTER PROCEDURE MasterBookingProc
-- declare any external variables
@Bookings BookingList READONLY

AS
BEGIN
-- declare any internal variables
    DECLARE @RetryCount INT = 0;
    DECLARE @MaxRetries INT = 3;
    DECLARE @Success BIT = 0;
    DECLARE @InvalidMemberID INT;
    DECLARE @FullClassID INT;
    DECLARE @DupMemberID INT;
    DECLARE @DupScheduleID INT;
    DECLARE @ErrorMessage NVARCHAR(MAX);
    DECLARE @ErrorState INT = 1;
    DECLARE @ErrorSeverity INT = 16;
 
    -- perform all reads of data/populate
    BEGIN TRY
        WHILE (@RetryCount < @MaxRetries AND @Success = 0)
        BEGIN
            BEGIN TRY
                SET @RetryCount = @RetryCount + 1;
                
                -- Start transaction with appropriate isolation level
                SET TRANSACTION ISOLATION LEVEL READ COMMITTED;
                BEGIN TRANSACTION;
                
                -- Business Logic 1: Check if all members have active memberships
                SELECT TOP 1 @InvalidMemberID = b.MemberID
                FROM @Bookings b
                LEFT JOIN Memberships m ON b.MemberID = m.MemberID
                WHERE m.MemberID IS NULL 
                OR m.Active = 0 
                OR GETDATE() NOT BETWEEN m.StartDate AND m.EndDate;
                
                IF (@InvalidMemberID IS NOT NULL)
                BEGIN
                    SET @ErrorMessage = 'Sorry, Member ' + CAST(@InvalidMemberID AS NVARCHAR) 
                                        + ' does not have an active membership plan';
                    RAISERROR(@ErrorMessage, @ErrorSeverity, @ErrorState);
                    ROLLBACK TRANSACTION;
                    RETURN;
                END;
                    
                -- Business Logic 2: Check if all classes have available capacity
                SELECT TOP 1 @FullClassID = cs.ScheduleID
                FROM @Bookings b
                JOIN ClassSchedule cs ON b.ScheduleID = cs.ScheduleID
                WHERE cs.CurrentBookings >= cs.MaxCapacity;
                
                IF (@FullClassID IS NOT NULL)
                BEGIN
                    SET @ErrorMessage = 'Sorry, class ' + CAST(@FullClassID AS NVARCHAR) 
                                        + ' is already at full capacity';
                    RAISERROR(@ErrorMessage, @ErrorSeverity, @ErrorState);
                    ROLLBACK TRANSACTION;
                    RETURN;
                END;
                
                -- Business Logic 3: Check for duplicate bookings
                SELECT TOP 1 
                    @DupMemberID = b.MemberID,
                    @DupScheduleID = b.ScheduleID
                FROM @Bookings b
                JOIN Bookings existing 
                    ON b.MemberID = existing.MemberID 
                    AND b.ScheduleID = existing.ScheduleID;
                
                IF (@DupMemberID IS NOT NULL)
                BEGIN
                    SET @ErrorMessage = 'Member ' + CAST(@DupMemberID AS NVARCHAR) 
                                        + ' has already booked class ' + CAST(@DupScheduleID AS NVARCHAR);
                    RAISERROR(@ErrorMessage, @ErrorSeverity, @ErrorState);
                    ROLLBACK TRANSACTION;
                    RETURN;
                END;
                
                -- At this point, all validations have passed
                
                -- Call InsertBookings stored procedure
                EXEC InsertBookings @Bookings = @Bookings;
                
                -- Call UpdateClassCapacity stored procedure
                EXEC UpdateClassCapacity @Bookings = @Bookings;
                
                COMMIT TRANSACTION;
                SET @Success = 1;
                
                PRINT 'Bookings successfully processed and class capacities updated';
            END TRY
            BEGIN CATCH
                IF XACT_STATE() <> 0
                    ROLLBACK TRANSACTION;
                    
                -- Check if error is a deadlock
                IF ERROR_NUMBER() = 1205
                BEGIN
                    -- Deadlock error, retry if not exceeded max retries
                    IF @RetryCount >= @MaxRetries
                    BEGIN
                        SET @ErrorMessage = 'Maximum retries exceeded. Please submit your booking again.';
                        RAISERROR(@ErrorMessage, @ErrorSeverity, @ErrorState);
                        RETURN;
                    END
                    
                    -- Wait a bit before retrying
                    WAITFOR DELAY '00:00:00.1';
                END
                ELSE
                BEGIN
                    -- Re-throw the current error
                    DECLARE @ErrorNum INT = ERROR_NUMBER();
                    SET @ErrorMessage = ERROR_MESSAGE();
                    
                    RAISERROR(@ErrorMessage, @ErrorSeverity, @ErrorState);
                    RETURN;
                END
            END CATCH
        END
    END TRY
    BEGIN CATCH
        -- Error handling and transaction rollback
        IF @@TRANCOUNT > 0
            ROLLBACK TRANSACTION;
            
        DECLARE @FinalErrorNum INT = ERROR_NUMBER(),
                @FinalErrorMsg NVARCHAR(4000) = ERROR_MESSAGE();
                
        -- If the error number isn't one I set, raise it since its an SQL problem
        IF @FinalErrorNum NOT BETWEEN 50000 AND 50099
        BEGIN
            RAISERROR(@FinalErrorMsg, 16, 1);
        END
        ELSE
        BEGIN
            -- Else it is one of our errors and send it to the user to see
            RAISERROR(@FinalErrorMsg, 16, 1);
        END
    END CATCH
END
GO