SET FEEDBACK ON
SET SERVEROUTPUT ON

-- ============================================================================
-- XX_ORDER_HOLDS_PKG - Order Holds Management Package
-- Registered with iRep as XxOrderHoldsPkg
-- Provides: apply/release customer-level order holds
-- ============================================================================

CREATE OR REPLACE PACKAGE APPS.XX_ORDER_HOLDS_PKG AS
/* $Header: XX_ORDER_HOLDS_PKG.pls 1.0 2026/03/08 00:00:00 applmgr ship $ */
/*#
 * Public API for applying and releasing Oracle Order Management holds on customer accounts.
 *
 * @rep:scope public
 * @rep:product ONT
 * @rep:displayname Order Holds Management
 * @rep:lifecycle active
 * @rep:compatibility S
 * @rep:category BUSINESS_ENTITY OE_ORDER
 */

/*#
 * Applies an order hold to all open sales orders for a given customer account.
 *
 * @param p_cust_account_id Customer Account ID
 * @param p_hold_id Hold ID to apply (default 1 = Credit Check Failure)
 * @param p_hold_comment Optional comment for the hold
 * @param x_return_status Return status: S=Success, E=Error
 * @param x_msg_count Number of messages
 * @param x_msg_data Error message text
 * @param x_orders_held Number of orders placed on hold
 * @rep:scope public
 * @rep:lifecycle active
 * @rep:displayname Apply Order Holds
 */
PROCEDURE APPLY_HOLDS (
  p_cust_account_id  IN  NUMBER,
  p_hold_id          IN  NUMBER   DEFAULT 1,
  p_hold_comment     IN  VARCHAR2 DEFAULT NULL,
  x_return_status    OUT NOCOPY VARCHAR2,
  x_msg_count        OUT NOCOPY NUMBER,
  x_msg_data         OUT NOCOPY VARCHAR2,
  x_orders_held      OUT NOCOPY NUMBER
);

/*#
 * Releases order holds from all held sales orders for a given customer account.
 *
 * @param p_cust_account_id Customer Account ID
 * @param p_hold_id Hold ID to release (default 1 = Credit Check Failure)
 * @param p_release_reason Release reason code (default AR_APPROVE)
 * @param x_return_status Return status: S=Success, E=Error
 * @param x_msg_count Number of messages
 * @param x_msg_data Error message text
 * @param x_orders_released Number of hold sources released
 * @rep:scope public
 * @rep:lifecycle active
 * @rep:displayname Release Order Holds
 */
PROCEDURE RELEASE_HOLDS (
  p_cust_account_id  IN  NUMBER,
  p_hold_id          IN  NUMBER   DEFAULT 1,
  p_release_reason   IN  VARCHAR2 DEFAULT 'AR_APPROVE',
  x_return_status    OUT NOCOPY VARCHAR2,
  x_msg_count        OUT NOCOPY NUMBER,
  x_msg_data         OUT NOCOPY VARCHAR2,
  x_orders_released  OUT NOCOPY NUMBER
);

END XX_ORDER_HOLDS_PKG;
/
SHOW ERRORS;


CREATE OR REPLACE PACKAGE BODY APPS.XX_ORDER_HOLDS_PKG AS

PROCEDURE APPLY_HOLDS (
  p_cust_account_id  IN  NUMBER,
  p_hold_id          IN  NUMBER   DEFAULT 1,
  p_hold_comment     IN  VARCHAR2 DEFAULT NULL,
  x_return_status    OUT NOCOPY VARCHAR2,
  x_msg_count        OUT NOCOPY NUMBER,
  x_msg_data         OUT NOCOPY VARCHAR2,
  x_orders_held      OUT NOCOPY NUMBER
) IS
  l_hold_source_rec  OE_HOLDS_PVT.Hold_Source_Rec_Type;
  l_return_status    VARCHAR2(1);
  l_msg_count        NUMBER;
  l_msg_data         VARCHAR2(2000);
  l_applied          NUMBER := 0;
BEGIN
  x_return_status := FND_API.G_RET_STS_SUCCESS;
  x_orders_held   := 0;

  FND_GLOBAL.APPS_INITIALIZE(0, 20678, 222);
  MO_GLOBAL.SET_POLICY_CONTEXT('S', 204);

  l_hold_source_rec.hold_id          := p_hold_id;
  l_hold_source_rec.hold_entity_code := 'C';
  l_hold_source_rec.hold_entity_id   := p_cust_account_id;
  l_hold_source_rec.hold_comment     := NVL(p_hold_comment, 'Collections hold applied');

  OE_HOLDS_PUB.APPLY_HOLDS(
    p_api_version       => 1.0,
    p_init_msg_list     => FND_API.G_TRUE,
    p_commit            => FND_API.G_FALSE,
    p_hold_source_rec   => l_hold_source_rec,
    x_return_status     => l_return_status,
    x_msg_count         => l_msg_count,
    x_msg_data          => l_msg_data
  );

  IF l_return_status = FND_API.G_RET_STS_SUCCESS THEN
    SELECT COUNT(*)
    INTO   l_applied
    FROM   oe_order_holds_all ooh
           JOIN oe_hold_sources_all ohs ON ooh.hold_source_id = ohs.hold_source_id
           JOIN oe_order_headers_all oha ON ooh.header_id = oha.header_id
    WHERE  ohs.hold_entity_code = 'C'
    AND    ohs.hold_entity_id   = p_cust_account_id
    AND    ohs.hold_id          = p_hold_id
    AND    ooh.released_flag    = 'N'
    AND    oha.open_flag        = 'Y';

    COMMIT;
    x_return_status := 'S';
    x_orders_held   := l_applied;
    x_msg_data      := 'APPLIED=' || l_applied;
  ELSE
    ROLLBACK;
    x_return_status := l_return_status;
    x_msg_count     := l_msg_count;
    x_msg_data      := l_msg_data;
  END IF;

EXCEPTION
  WHEN OTHERS THEN
    ROLLBACK;
    x_return_status := FND_API.G_RET_STS_UNEXP_ERROR;
    x_msg_data      := SQLERRM;
END APPLY_HOLDS;


PROCEDURE RELEASE_HOLDS (
  p_cust_account_id  IN  NUMBER,
  p_hold_id          IN  NUMBER   DEFAULT 1,
  p_release_reason   IN  VARCHAR2 DEFAULT 'AR_APPROVE',
  x_return_status    OUT NOCOPY VARCHAR2,
  x_msg_count        OUT NOCOPY NUMBER,
  x_msg_data         OUT NOCOPY VARCHAR2,
  x_orders_released  OUT NOCOPY NUMBER
) IS
  l_hold_source_rec   OE_HOLDS_PVT.Hold_Source_Rec_Type;
  l_hold_release_rec  OE_HOLDS_PVT.Hold_Release_Rec_Type;
  l_return_status     VARCHAR2(1);
  l_msg_count         NUMBER;
  l_msg_data          VARCHAR2(2000);
BEGIN
  x_return_status   := FND_API.G_RET_STS_SUCCESS;
  x_orders_released := 0;

  FND_GLOBAL.APPS_INITIALIZE(0, 20678, 222);
  MO_GLOBAL.SET_POLICY_CONTEXT('S', 204);

  l_hold_source_rec.hold_id          := p_hold_id;
  l_hold_source_rec.hold_entity_code := 'C';
  l_hold_source_rec.hold_entity_id   := p_cust_account_id;

  l_hold_release_rec.release_reason_code := p_release_reason;
  l_hold_release_rec.release_comment     := 'Collections hold released';

  OE_HOLDS_PUB.RELEASE_HOLDS(
    p_api_version        => 1.0,
    p_init_msg_list      => FND_API.G_TRUE,
    p_commit             => FND_API.G_FALSE,
    p_hold_source_rec    => l_hold_source_rec,
    p_hold_release_rec   => l_hold_release_rec,
    x_return_status      => l_return_status,
    x_msg_count          => l_msg_count,
    x_msg_data           => l_msg_data
  );

  IF l_return_status = FND_API.G_RET_STS_SUCCESS THEN
    COMMIT;
    x_return_status   := 'S';
    x_orders_released := 1;
    x_msg_data        := 'RELEASED=1';
  ELSE
    ROLLBACK;
    x_return_status := l_return_status;
    x_msg_count     := l_msg_count;
    x_msg_data      := l_msg_data;
  END IF;

EXCEPTION
  WHEN OTHERS THEN
    ROLLBACK;
    x_return_status := FND_API.G_RET_STS_UNEXP_ERROR;
    x_msg_data      := SQLERRM;
END RELEASE_HOLDS;

END XX_ORDER_HOLDS_PKG;
/
SHOW ERRORS;

GRANT EXECUTE ON APPS.XX_ORDER_HOLDS_PKG TO PUBLIC;

SELECT object_name, object_type, status
FROM user_objects
WHERE object_name = 'XX_ORDER_HOLDS_PKG'
ORDER BY object_type;

EXIT;
