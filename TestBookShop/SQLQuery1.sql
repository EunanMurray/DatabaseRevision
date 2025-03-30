USE BookWorldDB
GO

CREATE OR ALTER PROCEDURE BookMasterProc
    -- External variables - inputs to the stored procedure
    @ReturnList ReturnItemsList READONLY,  -- Table-valued parameter containing items to be returned
    @OrderID INT,                          -- The order ID associated with the return
    @ReturnDate DATETIME = NULL            -- Optional parameter for the return date (defaults to current date if not provided)
AS
BEGIN
    -- Declare internal variables used throughout the procedure
    DECLARE @RetryCount INT = 0;           -- Tracks number of transaction retry attempts
    DECLARE @MaxRetries INT = 3;           -- Maximum number of retry attempts for deadlock situations
    DECLARE @Success BIT = 0;              -- Flag to indicate successful transaction completion
    DECLARE @DaysAllowed INT = 30;         -- Maximum days allowed for returns
    DECLARE @DaysSinceOrder INT;           -- Calculated days between order and return date
    DECLARE @OrderItemID INT;              -- Used for processing individual return items
    DECLARE @BookID INT;                   -- Book ID associated with a return item
    DECLARE @QuantityReturned INT;         -- Quantity being returned
    DECLARE @ReturnReason NVARCHAR(200);   -- Reason for return
    DECLARE @UnitPrice DECIMAL(10,2);      -- Price of the item
    DECLARE @RefundAmount DECIMAL(10,2);   -- Calculated refund amount for a single item
    DECLARE @TotalRefund DECIMAL(10,2);    -- Total refund amount for all items
    DECLARE @NewReturnID INT;              -- ID of the newly created return record
    DECLARE @ErrorMessage NVARCHAR(MAX);   -- Variable to store error messages
    DECLARE @NotDeliveredOrderID INT;      -- Used to identify orders not in 'Delivered' status
    
    -- Set return date to current date if not provided
    IF @ReturnDate IS NULL
        SET @ReturnDate = GETDATE();
    
    -- Main processing loop with retry logic for handling deadlocks
    WHILE (@RetryCount < @MaxRetries AND @Success = 0)
    BEGIN 
        BEGIN TRY
            -- Increment retry counter
            SET @RetryCount = @RetryCount + 1;
            
            -- Set transaction isolation level
            -- READ COMMITTED prevents dirty reads while allowing non-repeatable reads
            -- This is appropriate for this scenario as we're validating then processing
            SET TRANSACTION ISOLATION LEVEL READ COMMITTED;
            BEGIN TRANSACTION;
            
            -- BUSINESS LOGIC 1: Check if return is within allowed period (30 days)
            -- This retrieves the order date and calculates the days since the order
            SELECT @DaysSinceOrder = DATEDIFF(DAY, o.OrderDate, @ReturnDate)
            FROM Orders o
            WHERE o.OrderID = @OrderID;
            
            -- If more than 30 days have passed, reject the return
            IF (@DaysSinceOrder > @DaysAllowed)
            BEGIN
                THROW 51000, 'Return Period Expired: Returns must be processed within 30 days of purchase', 1;
            END
            
            -- BUSINESS LOGIC 2: Check if requested return quantity exceeds available quantity
            -- This compares the requested return quantity against the original quantity minus previously returned items
            IF EXISTS (
                SELECT 1
                FROM @ReturnList r
                JOIN OrderItems oi ON r.OrderItemID = oi.OrderItemID
                LEFT JOIN (
                    -- Subquery to calculate previously returned quantities
                    SELECT OrderItemID, SUM(QuantityReturned) AS TotalReturned
                    FROM Returns
                    GROUP BY OrderItemID
                ) prev ON r.OrderItemID = prev.OrderItemID
                WHERE r.QuantityReturned > (oi.Quantity - ISNULL(prev.TotalReturned, 0))
            )
            BEGIN
                -- Return error if any item exceeds available quantity
                THROW 51001, 'Return quantity exceeds available quantity ordered.', 1;
            END
            
            -- BUSINESS LOGIC 3: Verify all orders are in 'Delivered' status
            -- Returns can only be processed for delivered orders
            IF EXISTS (
                SELECT 1
                FROM @ReturnList r
                JOIN OrderItems oi ON r.OrderItemID = oi.OrderItemID
                JOIN Orders o ON oi.OrderID = o.OrderID
                LEFT JOIN OrderDelivery od ON o.OrderID = od.OrderID
                WHERE od.DeliveryStatus <> 'Delivered' OR od.DeliveryStatus IS NULL
            )
            BEGIN
                -- Find the first non-delivered order for specific error message
                SELECT TOP 1 @NotDeliveredOrderID = o.OrderID
                FROM @ReturnList r
                JOIN OrderItems oi ON r.OrderItemID = oi.OrderItemID
                JOIN Orders o ON oi.OrderID = o.OrderID
                LEFT JOIN OrderDelivery od ON o.OrderID = od.OrderID
                WHERE od.DeliveryStatus <> 'Delivered' OR od.DeliveryStatus IS NULL;
                
               -- Throw error with specific order ID
				DECLARE @ErrorMsg NVARCHAR(200) = 'Order ' + CAST(@NotDeliveredOrderID AS NVARCHAR) + ' has not been delivered yet and cannot be returned';
				RAISERROR(@ErrorMsg, 16, 1);
				RETURN;
				END
            END
            
            -- BUSINESS LOGIC 4: Calculate total refund amount
            -- Refund = Unit Price × Quantity Returned for each item
            SELECT @TotalRefund = SUM(oi.UnitPrice * r.QuantityReturned)
            FROM @ReturnList r
            INNER JOIN OrderItems oi ON r.OrderItemID = oi.OrderItemID;
            
            -- Verify refund amount is valid
            IF (@TotalRefund IS NULL OR @TotalRefund <= 0)
            BEGIN
                THROW 51003, 'Refund calculation error: Invalid refund amount.', 1;
            END
            
            -- All validations have passed, now process the returns
            
            -- Process each return item using a cursor
            -- This allows us to handle each item individually and track progress
            DECLARE return_cursor CURSOR FOR
            SELECT r.OrderItemID, r.QuantityReturned, r.ReturnReason, oi.BookID, oi.UnitPrice
            FROM @ReturnList r
            JOIN OrderItems oi ON r.OrderItemID = oi.OrderItemID;
            
            OPEN return_cursor;
            FETCH NEXT FROM return_cursor INTO @OrderItemID, @QuantityReturned, @ReturnReason, @BookID, @UnitPrice;
            
            WHILE @@FETCH_STATUS = 0
            BEGIN
                -- Calculate refund amount for this specific item
                SET @RefundAmount = @UnitPrice * @QuantityReturned;
                
                -- Create return record for this item
                -- Call InsertReturn stored procedure or inline the code
                INSERT INTO Returns (
                    OrderItemID,
                    ReturnDate,
                    ReturnReason,
                    QuantityReturned,
                    RefundAmount,
                    ReturnStatus
                ) VALUES (
                    @OrderItemID,
                    @ReturnDate,
                    @ReturnReason,
                    @QuantityReturned,
                    @RefundAmount,
                    'Processing'
                );
                
                -- Get the ID of the inserted return
                SET @NewReturnID = SCOPE_IDENTITY();
                
                -- Update inventory by calling UpdateInventory procedure or inline the code
                -- First, get current stock level
                DECLARE @PreviousQuantity INT;
                SELECT @PreviousQuantity = AvailableStock
                FROM Books
                WHERE BookID = @BookID;
                
                -- Calculate and update new stock level
                DECLARE @NewQuantity INT = @PreviousQuantity + @QuantityReturned;
                
                UPDATE Books
                SET AvailableStock = @NewQuantity
                WHERE BookID = @BookID;
                
                -- Log the inventory change for audit purposes
                INSERT INTO InventoryLog (
                    BookID,
                    ChangeType,
                    QuantityChanged,
                    PreviousQuantity,
                    NewQuantity,
                    ChangeDate,
                    ReferenceType,
                    ReferenceID,
                    Notes
                ) VALUES (
                    @BookID,
                    'Return',
                    @QuantityReturned,
                    @PreviousQuantity,
                    @NewQuantity,
                    @ReturnDate,
                    'Return',
                    @NewReturnID,
                    'Book returned to inventory from order item ' + CAST(@OrderItemID AS NVARCHAR)
                );
                
                -- Move to next item
                FETCH NEXT FROM return_cursor INTO @OrderItemID, @QuantityReturned, @ReturnReason, @BookID, @UnitPrice;
            END
            
            -- Clean up cursor
            CLOSE return_cursor;
            DEALLOCATE return_cursor;
            
            -- All operations completed successfully
            COMMIT TRANSACTION;
            SET @Success = 1;
            
            -- Provide success message with details
            PRINT 'Returns processed successfully. Total refund amount: $' + CAST(@TotalRefund AS NVARCHAR);
            
        END TRY
        BEGIN CATCH
            -- Error handling within the retry loop
            
            -- Rollback the transaction if it's still active
            IF XACT_STATE() <> 0
                ROLLBACK TRANSACTION;
            
            -- Check if error is a deadlock (error 1205)
            -- Deadlocks can occur when multiple processes are trying to update the same resources
            IF ERROR_NUMBER() = 1205
            BEGIN
                -- If maximum retries exceeded, throw final error
                IF @RetryCount >= @MaxRetries
                BEGIN
                    SET @ErrorMessage = 'Maximum retries exceeded. Please submit your return request again.';
                    THROW 51004, @ErrorMessage, 1;
                END
                
                -- Wait a bit before retrying to allow other transactions to complete
                WAITFOR DELAY '00:00:00.1';
                
                -- Continue the loop for another retry
                PRINT 'Deadlock detected, retrying transaction. Attempt ' + CAST(@RetryCount AS NVARCHAR) + ' of ' + CAST(@MaxRetries AS NVARCHAR);
            END
            ELSE
            BEGIN
                -- For non-deadlock errors, clean up and re-throw
                
                -- Clean up cursor if it's still open
                IF CURSOR_STATUS('local', 'return_cursor') >= 0
                BEGIN
                    CLOSE return_cursor;
                    DEALLOCATE return_cursor;
                END
                
                -- Get error details
                DECLARE @ErrorNum INT = ERROR_NUMBER();
                SET @ErrorMessage = ERROR_MESSAGE();
                
                -- Re-throw the error to the outer catch block
                THROW;
            END
        END CATCH
    END -- End of retry loop
    
    -- Outer error handling
    BEGIN TRY
        -- Additional cleanup if needed
        IF CURSOR_STATUS('local', 'return_cursor') >= 0
        BEGIN
            CLOSE return_cursor;
            DEALLOCATE return_cursor;
        END
    END TRY
    BEGIN CATCH
        -- This should only execute if the cleanup itself fails
        PRINT 'Error during cleanup: ' + ERROR_MESSAGE();
    END CATCH
    
END
GO