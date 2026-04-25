/**
 * Supabase Edge Function: bunq webhook listener
 *
 * Receives bunq payment events and updates order status from pending_payment → confirmed
 * when the payment is accepted.
 *
 * Deployment:
 *   supabase functions deploy bunq-webhook --project-id <project-id>
 *
 * Register with bunq:
 *   POST https://your-project.supabase.co/functions/v1/bunq-webhook
 */

import { createClient } from "https://esm.sh/@supabase/supabase-js@2.39.3";

interface BunqPayment {
  id: number | string;
  status: string;
  [key: string]: unknown;
}

interface BunqWebhookPayload {
  NotificationUrl?: {
    event_type?: string;
    category?: string;
    object?: {
      Payment?: BunqPayment | BunqPayment[];
      [key: string]: unknown;
    };
  };
}

Deno.serve(async (req: Request) => {
  // Only accept POST requests
  if (req.method !== "POST") {
    return new Response(JSON.stringify({ error: "Method not allowed" }), {
      status: 405,
      headers: { "Content-Type": "application/json" },
    });
  }

  try {
    const payload: BunqWebhookPayload = await req.json();
    const notification = payload.NotificationUrl || {};
    const eventType = (notification.event_type || "").toUpperCase();
    const category = (notification.category || "").toUpperCase();

    console.log(`bunq webhook: event_type=${eventType}, category=${category}`);

    // Only process PAYMENT events
    if (eventType !== "PAYMENT" || category !== "PAYMENT") {
      console.log(`bunq webhook: ignoring event type=${eventType}`);
      return new Response(JSON.stringify({ ok: true }), { status: 200 });
    }

    const obj = notification.object || {};
    let payments = obj.Payment || [];
    if (!Array.isArray(payments)) {
      payments = [payments];
    }

    // Initialize Supabase client
    const supabaseUrl = Deno.env.get("SUPABASE_URL");
    const supabaseServiceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");

    if (!supabaseUrl || !supabaseServiceKey) {
      console.error("Missing SUPABASE_URL or SUPABASE_SERVICE_ROLE_KEY");
      return new Response(
        JSON.stringify({ error: "Server configuration error" }),
        { status: 500, headers: { "Content-Type": "application/json" } }
      );
    }

    const supabase = createClient(supabaseUrl, supabaseServiceKey);

    // Process each payment
    for (const payment of payments) {
      if (typeof payment !== "object" || !payment) continue;

      const paymentId = String(payment.id || "");
      const status = (payment.status || "").toUpperCase();

      if (!paymentId) {
        console.warn(`bunq webhook: payment has no id: ${JSON.stringify(payment)}`);
        continue;
      }

      console.log(`bunq webhook: payment_id=${paymentId}, status=${status}`);

      // Mark order as confirmed when payment is accepted
      if (status === "ACCEPTED") {
        try {
          const { error } = await supabase
            .from("orders")
            .update({ order_status: "confirmed" })
            .eq("bunq_transaction_id", paymentId);

          if (error) {
            console.error(
              `bunq webhook: failed to update order for payment ${paymentId}:`,
              error
            );
          } else {
            console.log(
              `bunq webhook: marked order confirmed for bunq_transaction_id=${paymentId}`
            );
          }
        } catch (exc) {
          console.error(
            `bunq webhook: error updating order for payment ${paymentId}:`,
            exc
          );
        }
      } else if (status === "REJECTED") {
        // Optionally mark as cancelled on rejection
        try {
          await supabase
            .from("orders")
            .update({ order_status: "cancelled" })
            .eq("bunq_transaction_id", paymentId);
          console.log(`bunq webhook: marked order cancelled for payment ${paymentId}`);
        } catch (exc) {
          console.error(`bunq webhook: error cancelling order for payment ${paymentId}:`, exc);
        }
      } else {
        console.log(`bunq webhook: payment ${paymentId} status=${status} (no action)`);
      }
    }

    return new Response(JSON.stringify({ ok: true }), {
      status: 200,
      headers: { "Content-Type": "application/json" },
    });
  } catch (error) {
    console.error("bunq webhook: error processing request:", error);
    return new Response(JSON.stringify({ error: "Invalid request" }), {
      status: 400,
      headers: { "Content-Type": "application/json" },
    });
  }
});
