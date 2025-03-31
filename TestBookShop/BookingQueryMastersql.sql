-- Create user-defined table type for Member IDs
USE BookingDB;
GO

-- Master Booking Procedure (Q4)
CREATE OR ALTER PROCEDURE dbo.BookingMasterProc
    @FacilityID INT,
    @BookingStartTime DATETIME,
    @BookingEndTime DATETIME,
    @BookedByMemberID INT,
    @MemberIDs dbo.MemberIDList READONLY
AS
BEGIN
    -- IPO (Input-Process-Output) Documentation
    -- Input: Facility ID, booking times, booking member ID, table of all member IDs participating
    -- Process: Validate booking, insert booking, add members, update earnings
    -- Output: Success or failure of booking operation
    
    DECLARE @RetryCount INT = 0;
    DECLARE @MaxRetries INT = 3;
    DECLARE @Success BIT = 0;
    DECLARE @ExistingBookingID INT = NULL;
    DECLARE @AdultCount INT;
    DECLARE @JuvenileCount INT;
    DECLARE @ValidationResult INT;
    DECLARE @BookingID INT;
    DECLARE @HoursBooked DECIMAL(10,2);
    DECLARE @CostPerHour DECIMAL(5,2);
    DECLARE @TotalEarnings DECIMAL(10,2);
    DECLARE @ErrorMessage NVARCHAR(4000);
    DECLARE @ErrorSeverity INT;
    DECLARE @ErrorState INT;
    
    WHILE (@RetryCount < @MaxRetries AND @Success = 0)
    BEGIN
        BEGIN TRY
            SET @RetryCount += 1;
            SET TRANSACTION ISOLATION LEVEL READ COMMITTED;
            BEGIN TRANSACTION;
            
            -- Two-phase locking approach: first acquire all locks
            
            -- Phase 1: Validation and lock acquisition
            
            -- Check for overlapping bookings using variable instead of EXISTS
            SELECT TOP 1 @ExistingBookingID = BookingID
            FROM Bookings WITH (UPDLOCK, HOLDLOCK)
            WHERE FacilityID = @FacilityID
              AND (@BookingStartTime < BookingEnd)
              AND (@BookingEndTime > BookingStart);
            
            -- Instead of IF EXISTS, use variable check
            IF (@ExistingBookingID IS NOT NULL)
            BEGIN
                RAISERROR('Facility already booked during this time slot.', 16, 1);
                ROLLBACK TRANSACTION;
                RETURN;
            END;
            
            -- Check for at least one adult if juveniles are included
            SELECT @AdultCount = COUNT(*)
            FROM Members
            WHERE MemberID IN (SELECT MemberID FROM @MemberIDs)
              AND MembershipType = 'Adult';
            
            -- Check if any juvenile is in the booking
            SELECT @JuvenileCount = COUNT(*)
            FROM Members
            WHERE MemberID IN (SELECT MemberID FROM @MemberIDs)
              AND MembershipType = 'Juvenile';
            
            -- Use CASE statement for multiple conditions on same variable
            SET @ValidationResult = 
                CASE 
                    WHEN @JuvenileCount > 0 AND @AdultCount = 0 THEN 1 -- Error: Juvenile without adult
                    WHEN @BookingEndTime <= @BookingStartTime THEN 2 -- Error: Invalid time range
                    ELSE 0 -- Success
                END;
            
            -- Handle validation results
            IF @ValidationResult = 1
            BEGIN
                RAISERROR('At least one adult must be present when juveniles are included in the booking.', 16, 1);
                ROLLBACK TRANSACTION;
                RETURN;
            END
            ELSE IF @ValidationResult = 2
            BEGIN
                RAISERROR('Booking end time must be after booking start time.', 16, 1);
                ROLLBACK TRANSACTION;
                RETURN;
            END
            ELSE
            BEGIN
                -- Phase 2: Execute operations now that locks are acquired
                
                -- Call procedure to insert booking (Q1)
                EXEC dbo.InsertBookingProc
                    @FacilityID = @FacilityID,
                    @BookingStartTime = @BookingStartTime,
                    @BookingEndTime = @BookingEndTime,
                    @BookedByMemberID = @BookedByMemberID,
                    @BookingID = @BookingID OUTPUT;
                
                -- Call procedure to insert booking members (Q2)
                EXEC dbo.InsertBookingMembersProc
                    @BookingID = @BookingID,
                    @MemberIDs = @MemberIDs;
                
                -- Calculate booking duration in hours (rounded up)
                SET @HoursBooked = CEILING(DATEDIFF(MINUTE, @BookingStartTime, @BookingEndTime) / 60.0);
                
                -- Get cost per hour for the facility
                SELECT @CostPerHour = CostPerHour
                FROM Facilities
                WHERE FacilityID = @FacilityID;
                
                -- Calculate total earnings
                SET @TotalEarnings = @HoursBooked * @CostPerHour;
                
                -- Update facility earnings (assuming 'Earnings' column exists)
                UPDATE Facilities
                SET Earnings = ISNULL(Earnings, 0) + @TotalEarnings
                WHERE FacilityID = @FacilityID;
                
                COMMIT TRANSACTION;
                SET @Success = 1;
            END;
        END TRY
        BEGIN CATCH
            IF @@TRANCOUNT > 0
                ROLLBACK TRANSACTION;
            
            -- Only retry on deadlock or lock timeout errors
            IF ERROR_NUMBER() IN (1205, 1222) -- Deadlock victim (1205) or lock timeout (1222)
            BEGIN
                -- Wait briefly before retrying to reduce contention
                WAITFOR DELAY '00:00:00.1'; -- 100 ms delay
                CONTINUE;
            END
            ELSE
            BEGIN
                -- For other errors, capture details and re-throw
                SELECT 
                    @ErrorMessage = ERROR_MESSAGE(),
                    @ErrorSeverity = ERROR_SEVERITY(),
                    @ErrorState = ERROR_STATE();
                
                RAISERROR(@ErrorMessage, @ErrorSeverity, @ErrorState);
                RETURN;
            END
        END CATCH;
    END;
    
    IF @Success = 0
        RAISERROR('Failed to complete booking after maximum retry attempts.', 16, 1);
END;
GO