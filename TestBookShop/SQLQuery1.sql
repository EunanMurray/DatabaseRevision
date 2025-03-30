USE BookWorldDB
GO

-- Procedure to handle returns of ordered items
CREATE OR ALTER PROCEDURE BookMasterProc
    @ReturnList ReturnItemsList READONLY, -- List of items being returned
    @OrderID INT,                         -- The ID of the order
    @ReturnDate DATETIME = NULL           -- The date of the return (optional, defaults to current date)
AS
BEGIN
    -- Initialize variables for transaction retry logic
    DECLARE @RetryCount INT = 0;
    DECLARE @MaxRetries INT = 3;
    DECLARE @Success BIT = 0;

    -- Define limits and parameters for return validation
    DECLARE @DaysAllowed INT = 30;    -- Max days after order to allow return
    DECLARE @DaysSinceOrder INT;

    -- Variables to process returns
    DECLARE @OrderItemID INT;
    DECLARE @BookID INT;
    DECLARE @QuantityReturned INT;
    DECLARE @ReturnReason NVARCHAR(200);
    DECLARE @UnitPrice DECIMAL(10,2);
    DECLARE @RefundAmount DECIMAL(10,2);
    DECLARE @TotalRefund DECIMAL(10,2);
    DECLARE @NewReturnID INT;
    DECLARE @NotDeliveredOrderID INT;

    -- Set return date to today if not provided
    IF @ReturnDate IS NULL
        SET @ReturnDate = GETDATE();

    -- Retry loop to handle potential deadlocks
    WHILE (@RetryCount < @MaxRetries AND @Success = 0)
    BEGIN 
        BEGIN TRY
            SET @RetryCount += 1;

            SET TRANSACTION ISOLATION LEVEL READ COMMITTED;
            BEGIN TRANSACTION;

            -- Check if return is within the allowed time frame
            SELECT @DaysSinceOrder = DATEDIFF(DAY, OrderDate, @ReturnDate)
            FROM Orders
            WHERE OrderID = @OrderID;

            IF (@DaysSinceOrder > @DaysAllowed)
                THROW 51000, 'Return Period Expired: Returns must be processed within 30 days of purchase.', 1;

            -- Verify return quantities do not exceed originally ordered quantity
            IF EXISTS (
                SELECT 1
                FROM @ReturnList r
                JOIN OrderItems oi ON r.OrderItemID = oi.OrderItemID
                LEFT JOIN (
                    -- Calculate total previously returned quantity for each item
                    SELECT OrderItemID, SUM(QuantityReturned) AS TotalReturned
                    FROM Returns
                    GROUP BY OrderItemID
                ) prev ON r.OrderItemID = prev.OrderItemID
                WHERE r.QuantityReturned > (oi.Quantity - ISNULL(prev.TotalReturned, 0))
            )
            BEGIN
                -- Throw error if any return exceeds allowable quantity
                THROW 51001, 'Return quantity exceeds available quantity ordered.', 1;
            END

            -- Check if all orders involved are in 'Delivered' status
            IF EXISTS (
                SELECT 1
                FROM @ReturnList r
                JOIN OrderItems oi ON r.OrderItemID = oi.OrderItemID
                JOIN Orders o ON oi.OrderID = o.OrderID
                LEFT JOIN OrderDelivery od ON o.OrderID = od.OrderID
                WHERE od.DeliveryStatus <> 'Delivered' OR od.DeliveryStatus IS NULL
            )
            BEGIN
                SELECT TOP 1 @NotDeliveredOrderID = o.OrderID
                FROM @ReturnList r
                JOIN OrderItems oi ON r.OrderItemID = oi.OrderItemID
                JOIN Orders o ON oi.OrderID = o.OrderID
                LEFT JOIN OrderDelivery od ON o.OrderID = od.OrderID
                WHERE od.DeliveryStatus <> 'Delivered' OR od.DeliveryStatus IS NULL;

                DECLARE @ErrorMsg NVARCHAR(200);
                SET @ErrorMsg = 'Order ' + CAST(@NotDeliveredOrderID AS NVARCHAR(50)) + ' has not been delivered yet and cannot be returned';
                RAISERROR(@ErrorMsg, 16, 1);
                RETURN;
            END

            -- Calculate total refund amount for all items
            SELECT @TotalRefund = SUM(oi.UnitPrice * r.QuantityReturned)
            FROM @ReturnList r
            INNER JOIN OrderItems oi ON r.OrderItemID = oi.OrderItemID;

            IF (@TotalRefund IS NULL OR @TotalRefund <= 0)
                THROW 51003, 'Refund calculation error: Invalid refund amount.', 1;

            -- Process each return individually
            DECLARE return_cursor CURSOR FOR
                SELECT r.OrderItemID, r.QuantityReturned, r.ReturnReason, oi.BookID, oi.UnitPrice
                FROM @ReturnList r
                JOIN OrderItems oi ON r.OrderItemID = oi.OrderItemID;

            OPEN return_cursor;
            FETCH NEXT FROM return_cursor INTO @OrderItemID, @QuantityReturned, @ReturnReason, @BookID, @UnitPrice;

            WHILE @@FETCH_STATUS = 0
            BEGIN
                SET @RefundAmount = @UnitPrice * @QuantityReturned;

                -- Insert return details into Returns table
                INSERT INTO Returns (OrderItemID, ReturnDate, ReturnReason, QuantityReturned, RefundAmount, ReturnStatus)
                VALUES (@OrderItemID, @ReturnDate, @ReturnReason, @QuantityReturned, @RefundAmount, 'Processing');

                SET @NewReturnID = SCOPE_IDENTITY();

                -- Update inventory levels
                DECLARE @PreviousQuantity INT;
                SELECT @PreviousQuantity = AvailableStock FROM Books WHERE BookID = @BookID;
                DECLARE @NewQuantity INT = @PreviousQuantity + @QuantityReturned;

                UPDATE Books SET AvailableStock = @NewQuantity WHERE BookID = @BookID;

                -- Log inventory changes
                INSERT INTO InventoryLog (BookID, ChangeType, QuantityChanged, PreviousQuantity, NewQuantity, ChangeDate, ReferenceType, ReferenceID, Notes)
                VALUES (@BookID, 'Return', @QuantityReturned, @PreviousQuantity, @NewQuantity, @ReturnDate, 'Return', @NewReturnID, 'Returned from OrderItem ' + CAST(@OrderItemID AS NVARCHAR(50)));

                FETCH NEXT FROM return_cursor INTO @OrderItemID, @QuantityReturned, @ReturnReason, @BookID, @UnitPrice;
            END

            CLOSE return_cursor;
            DEALLOCATE return_cursor;

            COMMIT TRANSACTION;
            SET @Success = 1;

            PRINT 'Returns processed successfully. Total refund: $' + CAST(@TotalRefund AS NVARCHAR(50));
        END TRY
        BEGIN CATCH
            IF XACT_STATE() <> 0
                ROLLBACK TRANSACTION;

            IF ERROR_NUMBER() = 1205 AND @RetryCount < @MaxRetries
            BEGIN
                WAITFOR DELAY '00:00:00.1';
                PRINT 'Deadlock detected, retrying transaction. Attempt ' + CAST(@RetryCount AS NVARCHAR(10));
            END
            ELSE
                THROW;
        END CATCH
    END
END
GO