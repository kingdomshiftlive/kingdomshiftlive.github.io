export const COIN_PRODUCTS = Object.freeze({
  coins_100: { amount: 99, credits: 100 },
  coins_500: { amount: 499, credits: 550 },
  coins_1200: { amount: 999, credits: 1400 },
  coins_3500: { amount: 2499, credits: 4200 },
  coins_7000: { amount: 4999, credits: 8500 },
  coins_15000: { amount: 9999, credits: 20000 },
});
export const PRO_MONTHLY_CENTS = 1900;
export class HttpError extends Error {
  constructor(status, message) {
    super(message);
    this.status = status;
  }
}
const uuid = (value) =>
  /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i
    .test(value || "");
const good = async (query) => {
  const { data, error } = await query;
  if (error) {
    throw new HttpError(
      error.code === "42501" ? 403 : 400,
      "The service request could not be completed. Please retry.",
    );
  }
  return data;
};
async function textBody(request, limit = 131072) {
  const reader = request.body?.getReader();
  if (!reader) return "";
  const chunks = [];
  let size = 0;
  for (;;) {
    const { value, done } = await reader.read();
    if (done) break;
    size += value.byteLength;
    if (size > limit) {
      await reader.cancel();
      throw new HttpError(413, "Request is too large");
    }
    chunks.push(value);
  }
  const bytes = new Uint8Array(size);
  let offset = 0;
  for (const chunk of chunks) {
    bytes.set(chunk, offset);
    offset += chunk.length;
  }
  return new TextDecoder().decode(bytes);
}
export function createPlatformHandler(
  {
    admin,
    stripe,
    verifyWebhook,
    issueToken,
    settings,
    now = () => Date.now(),
  },
) {
  const site = new URL(settings.siteURL);
  const allowed = new Set([site.origin, ...(settings.allowedOrigins || [])]);
  const billing = !!stripe && !!verifyWebhook &&
    ["test", "live"].includes(settings.billingMode) &&
    (settings.billingMode !== "live" || settings.liveBillingApproved === true);
  const streaming = !!settings.streamingEnabled &&
    Number.isSafeInteger(settings.zegoAppId) && !!issueToken;
  const reply = (status, data, origin) =>
    new Response(JSON.stringify(data), {
      status,
      headers: {
        "Content-Type": "application/json",
        "Cache-Control": "no-store",
        "X-Content-Type-Options": "nosniff",
        "Referrer-Policy": "no-referrer",
        ...(origin && allowed.has(origin)
          ? { "Access-Control-Allow-Origin": origin, Vary: "Origin" }
          : {}),
      },
    });
  async function identify(request) {
    const header = request.headers.get("authorization") || "";
    if (!header.startsWith("Bearer ")) {
      throw new HttpError(401, "Sign in to continue");
    }
    const { data, error } = await admin.auth.getUser(header.slice(7));
    if (error || !data?.user) {
      throw new HttpError(401, "Your session expired. Sign in again.");
    }
    const profile = await good(
      admin.from("profiles").select("id,role,suspended,display_name,username")
        .eq("id", data.user.id).single(),
    );
    if (!profile || profile.suspended || profile.role === "deleted") {
      throw new HttpError(403, "This account is inactive. Contact support.");
    }
    return { ...data.user, profile };
  }
  async function canView(user, creator) {
    if (user.id === creator) return true;
    const profile = await good(
      admin.from("profiles").select("id,suspended,privacy_settings").eq(
        "id",
        creator,
      ).maybeSingle(),
    );
    if (!profile || profile.suspended) return false;
    if (String(profile.privacy_settings?.privateAccount) !== "true") {
      return true;
    }
    const follow = await good(
      admin.from("follows").select("status").eq("follower_id", user.id).eq(
        "following_id",
        creator,
      ).eq("status", "accepted").maybeSingle(),
    );
    return !!follow;
  }
  async function checkout(user, body) {
    if (
      !billing ||
      await good(admin.rpc("billing_environment")) !== settings.billingMode
    ) {
      throw new HttpError(
        503,
        "Checkout is not enabled. No payment has been taken.",
      );
    }
    if (
      !uuid(body.request_key) ||
      !["coins", "pro", "shop"].includes(body.kind) ||
      typeof body.product_id !== "string"
    ) throw new HttpError(400, "Invalid checkout request");
    let order = await good(
      admin.from("checkout_orders").select("*").eq("user_id", user.id).eq(
        "request_key",
        body.request_key,
      ).maybeSingle(),
    );
    if (
      order &&
      (order.kind !== body.kind || order.product_id !== body.product_id)
    ) throw new HttpError(409, "This request key belongs to another product");
    if (!order) {
      let product;
      if (body.kind === "coins") {
        product = Object.hasOwn(COIN_PRODUCTS, body.product_id)
          ? COIN_PRODUCTS[body.product_id]
          : null;
        if (!product) throw new HttpError(400, "Unknown coin package");
      } else if (body.kind === "pro") {
        if (!settings.proEnabled || body.product_id !== "creator_pro") {
          throw new HttpError(503, "Creator Pro is not enabled");
        }
        product = { amount: PRO_MONTHLY_CENTS, credits: 0 };
      } else {
        if (!uuid(body.product_id)) throw new HttpError(400, "Invalid product");
        const item = await good(
          admin.from("shop_items").select(
            "id,name,creator_id,active,price,file_path,type",
          ).eq("id", body.product_id).maybeSingle(),
        );
        if (
          !item?.active || !item.file_path ||
          !["Digital", "eBook"].includes(item.type) ||
          !await canView(user, item.creator_id)
        ) throw new HttpError(404, "This product is unavailable");
        if (item.creator_id === user.id) {
          throw new HttpError(400, "You already own this product");
        }
        product = {
          amount: Math.round(Number(item.price) * 100),
          credits: 0,
          item_id: item.id,
          seller_id: item.creator_id,
        };
        if (
          !Number.isSafeInteger(product.amount) || product.amount < 50 ||
          product.amount > 1000000
        ) throw new HttpError(400, "Product price is not supported");
      }
      const record = {
        id: crypto.randomUUID(),
        environment: settings.billingMode,
        user_id: user.id,
        request_key: body.request_key,
        kind: body.kind,
        product_id: body.product_id,
        amount_cents: product.amount,
        credits: product.credits,
        item_id: product.item_id || null,
        seller_id: product.seller_id || null,
      };
      const inserted = await admin.from("checkout_orders").insert(record)
        .select("*").single();
      if (inserted.error?.code === "23505") {
        order = await good(
          admin.from("checkout_orders").select("*").eq("user_id", user.id).eq(
            "request_key",
            body.request_key,
          ).single(),
        );
      } else {
        if (inserted.error) {
          throw new HttpError(503, "Checkout could not be prepared");
        }
        order = inserted.data;
      }
      if (order.kind !== body.kind || order.product_id !== body.product_id) {
        throw new HttpError(409, "This request key belongs to another product");
      }
    }
    if (order.status !== "pending") {
      throw new HttpError(
        409,
        "This checkout is already completed or under review",
      );
    }
    const metadata = { order_id: order.id, user_id: user.id };
    const session = await stripe.checkout.sessions.create({
      mode: order.kind === "pro" ? "subscription" : "payment",
      client_reference_id: order.id,
      metadata,
      ...(order.kind === "pro" ? { subscription_data: { metadata } } : {}),
      line_items: [{
        quantity: 1,
        price_data: {
          currency: "usd",
          unit_amount: order.amount_cents,
          product_data: {
            name: order.kind === "coins"
              ? `${order.credits} KingdomShift coins`
              : order.kind === "pro"
              ? "KingdomShift Creator Pro"
              : "KingdomShift digital purchase",
          },
          ...(order.kind === "pro" ? { recurring: { interval: "month" } } : {}),
        },
      }],
      success_url: new URL(`?checkout=${order.id}#purchases`, site).href,
      cancel_url: new URL("#shop", site).href,
    }, { idempotencyKey: "checkout:" + order.id });
    if (
      !session.url || !/^https:\/\/checkout\.stripe\.com\//.test(session.url)
    ) throw new HttpError(503, "Checkout could not be opened");
    await good(
      admin.from("checkout_orders").update({ stripe_session: session.id }).eq(
        "id",
        order.id,
      ),
    );
    return { url: session.url, order_id: order.id };
  }
  async function webhook(request) {
    if (!stripe || !verifyWebhook) {
      throw new HttpError(503, "Billing webhook is not configured");
    }
    let event;
    try {
      event = await verifyWebhook(
        await textBody(request, 1048576),
        request.headers.get("stripe-signature") || "",
      );
    } catch {
      throw new HttpError(400, "Invalid webhook signature");
    }
    if (
      event.livemode !==
        (settings.webhookLiveMode ?? (settings.billingMode === "live"))
    ) throw new HttpError(400, "Wrong payment mode");
    const object = event.data.object;
    if (
      ["checkout.session.completed", "checkout.session.async_payment_succeeded"]
        .includes(event.type)
    ) {
      if (object.payment_status !== "paid") return { received: true };
      if (!uuid(object.metadata?.order_id)) return { received: true };
      await good(admin.rpc("fulfill_checkout", {
        order_key: object.metadata.order_id,
        session_id: object.id,
        amount: object.amount_total,
        currency: object.currency,
        event_id: event.id,
        subscription_id: typeof object.subscription === "string"
          ? object.subscription
          : null,
      }));
      if (object.subscription) {
        await good(
          admin.from("billing_subscriptions").update({
            customer_id: object.customer,
          }).eq("id", object.subscription),
        );
        const sub = await stripe.subscriptions.retrieve(object.subscription);
        await good(
          admin.rpc("sync_subscription", {
            subscription_id: sub.id,
            subscription_status: sub.status,
          }),
        );
      }
      await good(
        admin.from("checkout_orders").update({
          payment_intent: typeof object.payment_intent === "string"
            ? object.payment_intent
            : null,
        }).eq("id", object.metadata.order_id),
      );
    } else if (
      ["checkout.session.expired", "checkout.session.async_payment_failed"]
        .includes(event.type)
    ) {
      if (uuid(object.metadata?.order_id)) {
        await good(
          admin.rpc("cancel_checkout", {
            order_key: object.metadata.order_id,
            session_id: object.id,
            event_id: event.id,
          }),
        );
      }
    } else if (
      [
        "customer.subscription.updated",
        "customer.subscription.deleted",
        "invoice.paid",
        "invoice.payment_failed",
      ].includes(event.type)
    ) {
      const id = event.type.startsWith("customer.subscription")
        ? object.id
        : object.subscription ||
          object.parent?.subscription_details?.subscription;
      if (id) {
        const sub = await stripe.subscriptions.retrieve(id);
        await good(
          admin.rpc("sync_subscription", {
            subscription_id: sub.id,
            subscription_status: sub.status,
          }),
        );
      }
    } else if (
      ["charge.refunded", "charge.dispute.created"].includes(event.type)
    ) {
      const charge = event.type === "charge.dispute.created"
        ? await stripe.charges.retrieve(object.charge)
        : object;
      if (charge.payment_intent) {
        await good(
          admin.rpc("flag_payment_incident", {
            intent: charge.payment_intent,
            event_key: event.id,
            incident_type: event.type,
          }),
        );
      }
    }
    return { received: true };
  }
  return async (request) => {
    const origin = request.headers.get("origin");
    try {
      if (origin && !allowed.has(origin)) {
        throw new HttpError(403, "Origin is not allowed");
      }
      if (request.method === "OPTIONS") {
        return new Response(null, {
          status: 204,
          headers: {
            "Access-Control-Allow-Origin": origin || site.origin,
            "Access-Control-Allow-Methods": "GET,POST,OPTIONS",
            "Access-Control-Allow-Headers":
              "authorization,apikey,content-type,x-client-info",
            "Access-Control-Max-Age": "600",
            Vary: "Origin",
          },
        });
      }
      const path =
        new URL(request.url).pathname.split("/platform").pop().replace(
          /\/$/,
          "",
        ) || "/";
      if (path === "/webhook" && request.method === "POST") {
        return reply(200, await webhook(request), origin);
      }
      if (path === "/health" && request.method === "GET") {
        const health = await good(admin.rpc("platform_health"));
        if (health?.schema_version !== 4) {
          throw new HttpError(503, "Database upgrade is required");
        }
        return reply(200, {
          ready: true,
          billing: billing &&
              await good(admin.rpc("billing_environment")) ===
                settings.billingMode
            ? settings.billingMode
            : "disabled",
          pro: billing && !!settings.proEnabled,
          erasure_processing: !!settings.deletionProcessingEnabled,
          streaming,
        }, origin);
      }
      const user = await identify(request);
      await good(
        admin.rpc("enforce_rate_limit", {
          actor: user.id,
          operation: "api:" + path.split("/")[1],
          maximum: 30,
        }),
      );
      const raw = request.method === "POST" ? await textBody(request) : "";
      let body = {};
      if (raw) {
        try {
          body = JSON.parse(raw);
        } catch {
          throw new HttpError(400, "Invalid JSON");
        }
        if (!body || Array.isArray(body) || typeof body !== "object") {
          throw new HttpError(400, "Invalid request");
        }
      }
      if (path === "/checkout" && request.method === "POST") {
        return reply(200, await checkout(user, body), origin);
      }
      if (path === "/billing-portal" && request.method === "POST") {
        if (!billing) throw new HttpError(503, "Billing is not enabled");
        const subscription = await good(
          admin.from("billing_subscriptions").select("customer_id").eq(
            "user_id",
            user.id,
          ).not("customer_id", "is", null).limit(1).maybeSingle(),
        );
        if (!subscription?.customer_id) {
          throw new HttpError(404, "No billing account found");
        }
        const portal = await stripe.billingPortal.sessions.create({
          customer: subscription.customer_id,
          return_url: new URL("#profile", site).href,
        });
        return reply(200, { url: portal.url }, origin);
      }
      if (path === "/streams" && request.method === "POST") {
        if (!streaming) throw new HttpError(503, "Streaming is not configured");
        if (
          typeof body.title !== "string" || body.title.trim().length < 1 ||
          body.title.length > 160
        ) throw new HttpError(400, "Enter a stream title up to 160 characters");
        const id = await good(
          admin.rpc("start_live_stream", {
            creator: user.id,
            stream_title: body.title.trim(),
          }),
        );
        return reply(200, { stream_id: id }, origin);
      }
      const streamMatch = path.match(
        /^\/streams\/(ks_[0-9a-f-]{36})\/(token|heartbeat|activate|end)$/i,
      );
      if (streamMatch && request.method === "POST") {
        if (!streaming) throw new HttpError(503, "Streaming is not configured");
        const [, id, operation] = streamMatch;
        const stream = await good(
          admin.from("live_streams").select(
            "id,creator_id,status,lease_expires_at",
          ).eq("id", id).maybeSingle(),
        );
        if (
          !stream || !["live", "preparing"].includes(stream.status) ||
          new Date(stream.lease_expires_at).getTime() <= now() ||
          !await canView(user, stream.creator_id)
        ) throw new HttpError(404, "Stream unavailable");
        const host = stream.creator_id === user.id;
        if (!host && stream.status !== "live") {
          throw new HttpError(404, "Broadcast has not started");
        }
        if (operation !== "token" && !host) {
          throw new HttpError(403, "Only the host can manage this stream");
        }
        if (operation === "token") {
          return reply(200, {
            app_id: settings.zegoAppId,
            token: issueToken({ userId: user.id, roomId: id, host }),
            room_id: id,
            user_id: user.id,
            host,
            expires_in: 600,
          }, origin);
        }
        await good(
          admin.from("live_streams").update(
            operation === "end"
              ? { status: "ended", ended_at: new Date(now()).toISOString() }
              : {
                ...(operation === "activate" ? { status: "live" } : {}),
                lease_expires_at: new Date(now() + 120000).toISOString(),
              },
          ).eq("id", id).eq("creator_id", user.id),
        );
        return reply(200, { ok: true }, origin);
      }
      const deletion = path.match(
        /^\/admin\/deletions\/([0-9a-f-]{36})\/process$/i,
      );
      if (deletion && request.method === "POST") {
        if (user.profile.role !== "admin") {
          throw new HttpError(403, "Administrator access required");
        }
        if (!settings.deletionProcessingEnabled) {
          throw new HttpError(
            503,
            "Erasure processing requires owner approval of retention and settlement procedures",
          );
        }
        const record = await good(
          admin.from("account_deletion_requests").select("*").eq(
            "id",
            deletion[1],
          ).single(),
        );
        if (record.status === "completed") {
          return reply(200, { completed: true }, origin);
        }
        if (record.user_id === user.id) {
          throw new HttpError(
            400,
            "Another administrator must process this request",
          );
        }
        await good(
          admin.rpc("prepare_account_erasure", {
            target: record.user_id,
            request_key: record.id,
          }),
        );
        for (const bucket of ["videos", "shop-files"]) {
          const queue = [record.user_id];
          let removed = 0;
          while (queue.length) {
            const prefix = queue.shift();
            if (prefix.split("/").length > 10) {
              throw new HttpError(
                409,
                "Storage structure requires manual review",
              );
            }
            for (;;) {
              const files = await good(
                admin.storage.from(bucket).list(prefix, {
                  limit: 100,
                  offset: 0,
                }),
              );
              if (!files?.length) break;
              const paths = files.filter((file) => file.id).map((file) =>
                prefix + "/" + file.name
              );
              for (const folder of files.filter((file) => !file.id)) {
                queue.push(prefix + "/" + folder.name);
              }
              if (paths.length) {
                await good(admin.storage.from(bucket).remove(paths));
              }
              removed += paths.length;
              if (removed > 1000) {
                throw new HttpError(
                  409,
                  "Cleanup made progress. Retry to continue.",
                );
              }
              if (!paths.length) break;
            }
          }
        }
        await good(
          admin.rpc("erase_account_data", {
            target: record.user_id,
            request_key: record.id,
          }),
        );
        const authResult = await admin.auth.admin.deleteUser(record.user_id);
        if (authResult.error && authResult.error.status !== 404) {
          throw new HttpError(
            503,
            "Authentication erasure failed. Retry this request.",
          );
        }
        await good(
          admin.from("account_deletion_requests").update({
            status: "completed",
            completed_at: new Date(now()).toISOString(),
          }).eq("id", record.id),
        );
        return reply(200, { completed: true }, origin);
      }
      const download = path.match(/^\/purchases\/([0-9a-f-]{36})\/download$/i);
      if (download && request.method === "POST") {
        const purchase = await good(
          admin.from("purchases").select("id,item_id,checkout_orders(status)")
            .eq("id", download[1]).eq("user_id", user.id).maybeSingle(),
        );
        if (!purchase || purchase.checkout_orders?.status !== "paid") {
          throw new HttpError(404, "Purchase unavailable");
        }
        const item = await good(
          admin.from("shop_items").select("file_path").eq(
            "id",
            purchase.item_id,
          ).single(),
        );
        if (!item?.file_path) throw new HttpError(404, "Download unavailable");
        const data = await good(
          admin.storage.from("shop-files").createSignedUrl(item.file_path, 60, {
            download: true,
          }),
        );
        return reply(200, { url: data.signedUrl }, origin);
      }
      throw new HttpError(404, "Endpoint not found");
    } catch (error) {
      return reply(error instanceof HttpError ? error.status : 503, {
        error: error instanceof HttpError
          ? error.message
          : "The service is temporarily unavailable. Please retry.",
      }, origin);
    }
  };
}
