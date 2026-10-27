/* Integrations use authenticated Edge functions; no server credentials enter this file. */
async function platformRequest(path, body, method = "POST") {
  if (!sb?.functions) {
    throw new Error(
      "Service connection is not configured. Please contact support.",
    );
  }
  const { data, error } = await sb.functions.invoke("platform/" + path, {
    method,
    ...(body === undefined ? {} : { body }),
  });
  if (error) {
    let message = "The service could not complete this request. Please retry.";
    try {
      const payload = await error.context?.json();
      if (payload?.error) message = payload.error;
    } catch {}
    throw new Error(message);
  }
  if (data?.error) throw new Error(data.error);
  return data;
}
async function loadCapabilities() {
  try {
    S.capabilities = await platformRequest("health", undefined, "GET");
  } catch {
    S.capabilities = {
      ready: false,
      billing: "disabled",
      pro: false,
      streaming: false,
    };
  }
  if (["live", "shop", "profile"].includes(S.tab) && S.user) render();
}
function serviceReady(feature) {
  return S.capabilities?.ready && S.capabilities[feature] &&
    S.capabilities[feature] !== "disabled";
}
let checkoutRequest = null;
async function startCheckout(kind, product, button) {
  if (!serviceReady("billing")) {
    showToast(
      "Checkout is awaiting service configuration. No payment has been taken.",
    );
    return;
  }
  if (kind === "pro" && !S.capabilities.pro) {
    showToast("Creator Pro enrollment is not open yet.");
    return;
  }
  if (button?.disabled) return;
  busy(button, true);
  const signature = kind + ":" + product;
  if (checkoutRequest?.signature !== signature) {
    checkoutRequest = { signature, key: crypto.randomUUID() };
  }
  try {
    const result = await platformRequest("checkout", {
      kind,
      product_id: product,
      request_key: checkoutRequest.key,
    });
    const target = new URL(result.url);
    if (
      target.protocol !== "https:" || target.hostname !== "checkout.stripe.com"
    ) throw new Error("Invalid checkout destination");
    location.assign(target.href);
  } catch (error) {
    actionError(error);
    busy(button, false);
  }
}
purchaseCoins = function () {
  if (!selectedPkg) {
    showToast("Select a coin package.");
    return;
  }
  return startCheckout(
    "coins",
    selectedPkg.id,
    document.getElementById("buy-btn"),
  );
};
upgradeCreatorPro = function () {
  return startCheckout("pro", "creator_pro");
};
showCoinsModal = function () {
  selectedPkg = null;
  openDialog(
    "Coin Packages",
    `<p>${
      serviceReady("billing")
        ? (S.capabilities.billing === "test"
          ? "Test checkout — use Stripe test payment details only."
          : "Coins are credited only after confirmed payment.")
        : "Coin checkout is awaiting service configuration."
    }</p><div class="coin-grid">${
      COIN_PACKAGES.map((pkg) =>
        `<button type="button" class="coin-pkg" id="pkg-${pkg.id}" aria-pressed="false" onclick="selectPkg('${pkg.id}')"><span>${
          pkg.coins + pkg.bonus
        } coins</span><br><span>$${pkg.price}</span></button>`
      ).join("")
    }</div><button class="btn btn-teal" id="buy-btn" onclick="purchaseCoins()" ${
      !serviceReady("billing") ? "disabled" : ""
    }>Select a package</button>`,
  );
};
const originalSelectPackage = selectPkg;
selectPkg = function (id) {
  originalSelectPackage(id);
  if (selectedPkg) {
    const button = document.getElementById("buy-btn");
    if (button) {
      button.textContent = `Buy ${
        selectedPkg.coins + selectedPkg.bonus
      } coins for $${selectedPkg.price.toFixed(2)}`;
    }
  }
  document.querySelectorAll(".coin-pkg").forEach((button) =>
    button.setAttribute("aria-pressed", String(button.id === "pkg-" + id))
  );
};
requestWithdrawal = async function () {
  try {
    const id = await call("request_withdrawal");
    showToast(
      "Withdrawal request recorded: " + id +
        ". Funds are reserved pending review.",
    );
    render();
  } catch (error) {
    actionError(error);
  }
};
fetchShopItems = async function () {
  const { data, error } = await sb.from("shop_items").select(
    "id,creator_id,name,description,price,type,icon,profiles(display_name,username)",
  ).eq("active", true).order("created_at", { ascending: false }).limit(100);
  if (error) throw error;
  S.shopItems = data || [];
  return S.shopItems;
};
renderShop = async function (p) {
  p.innerHTML =
    '<div class="page-hdr"><h1 class="page-title">AuthorityShop</h1><p class="page-sub">Digital resources from our community.</p><div class="action-row"><button class="btn btn-glass" onclick="navigate(\'catalog\')">Manage my products</button><button class="btn btn-glass" onclick="navigate(\'purchases\')">My purchases</button></div><p id="shop-status" role="status">Loading products…</p></div><div class="shop-grid" id="shop-products"></div>';
  try {
    const items = await fetchShopItems();
    if (S.tab !== "shop") return;
    p.querySelector("#shop-status").textContent = serviceReady("billing")
      ? (S.capabilities.billing === "test"
        ? "Test checkout is active. No live payments are accepted."
        : "Payments are securely processed by Stripe.")
      : "Browse resources. Checkout is awaiting service configuration.";
    p.querySelector("#shop-products").innerHTML = items.map((item) =>
      `<article class="shop-card"><div class="sc-thumb">${
        escape(item.icon || "📚")
      }</div><div class="sc-body"><h2 class="sc-name">${
        escape(item.name)
      }</h2><p>${escape(item.description || "")}</p><p class="sc-creator">${
        escape(
          item.profiles?.display_name || item.profiles?.username || "Creator",
        )
      }</p><p class="sc-price">$${
        count(item.price).toFixed(2)
      }</p><button class="btn btn-teal" onclick="startCheckout('shop',${
        idArg(item.id)
      },this)" ${!serviceReady("billing") ? "disabled" : ""}>${
        S.capabilities?.billing === "test" ? "Test purchase" : "Purchase"
      }</button></div></article>`
    ).join("") || '<p class="empty-state">No approved products yet.</p>';
  } catch {
    const target = p.querySelector("#shop-status");
    if (target) target.textContent = "Products could not load. Please retry.";
  }
};
async function renderCatalog(p) {
  p.innerHTML =
    `<div class="page-hdr"><h1 class="page-title">Manage Products</h1><p>Submit a PDF, EPUB, or ZIP digital resource for review. Downloads are available only to confirmed purchasers.</p><form onsubmit="event.preventDefault();submitProduct(this)">${
      field("Product name", "product-name", "text", 'maxlength="160" required')
    }<label class="label" for="product-description">Description</label><textarea class="input" id="product-description" maxlength="5000" required></textarea>${
      field(
        "Price in USD",
        "product-price",
        "number",
        'min="0.50" max="10000" step="0.01" required',
      )
    }<label class="label" for="product-type">Type</label><select class="input" id="product-type"><option value="eBook">eBook</option><option value="Digital">Digital</option></select>${
      field(
        "Product file — up to 50 MB",
        "product-file",
        "file",
        'accept=".pdf,.epub,.zip" required',
      )
    }<button class="btn btn-teal" type="submit">Submit product for review</button><p id="form-status" role="status"></p></form></div><div class="content-list" id="catalog-list">Loading your products…</div>`;
  const target = p.querySelector("#catalog-list");
  try {
    const { data, error } = await sb.from("shop_items").select(
      "id,name,price,review_status",
    ).eq("creator_id", S.user.id).order("created_at", { ascending: false })
      .limit(100);
    if (error) throw error;
    if (target.isConnected) {
      target.innerHTML = (data || []).map((item) =>
        `<article class="content-card"><h2>${escape(item.name)}</h2><p>$${
          count(item.price).toFixed(2)
        } · ${
          escape(item.review_status)
        }</p><button class="btn btn-glass" onclick="archiveProduct(${
          idArg(item.id)
        })">Archive product</button></article>`
      ).join("") || "<p>No products submitted yet.</p>";
    }
  } catch {
    if (target.isConnected) target.textContent = "Products could not load.";
  }
}
async function submitProduct(form) {
  const button = form.querySelector("[type=submit]");
  busy(button, true);
  let path;
  try {
    const file = document.getElementById("product-file").files[0];
    const ext = file?.name.split(".").pop().toLowerCase();
    const types = {
      pdf: "application/pdf",
      epub: "application/epub+zip",
      zip: "application/zip",
    };
    if (!file || !types[ext] || file.size > 50 * 1024 * 1024) {
      throw new Error("Choose a PDF, EPUB, or ZIP file under 50 MB.");
    }
    path = `${S.user.id}/${crypto.randomUUID()}.${ext}`;
    formStatus("Uploading product…");
    const { error } = await sb.storage.from("shop-files").upload(path, file, {
      contentType: types[ext],
      upsert: false,
    });
    if (error) throw error;
    await call("save_shop_item", {
      item_key: null,
      item_name: document.getElementById("product-name").value.trim(),
      item_description: document.getElementById("product-description").value
        .trim(),
      item_price: Number(document.getElementById("product-price").value),
      item_type: document.getElementById("product-type").value,
      media_path: path,
    });
    showToast("Product submitted for review.");
    navigate("catalog");
  } catch (error) {
    formStatus(error.message);
  } finally {
    busy(button, false);
  }
}
async function archiveProduct(id) {
  if (
    !confirm(
      "Stop selling this product? Existing purchases retain download access.",
    )
  ) return;
  try {
    await call("archive_shop_item", { item_key: id });
    render();
  } catch (error) {
    actionError(error);
  }
}
async function renderPurchases(p) {
  p.innerHTML =
    '<div class="page-hdr"><h1 class="page-title">Purchases</h1><p>Payment confirmations may take a moment. Refresh if a recent checkout is still pending.</p><button class="btn btn-glass" onclick="render()">Refresh purchases</button></div><div class="content-list" id="purchase-list">Loading receipts…</div>';
  const target = p.querySelector("#purchase-list");
  try {
    const { data, error } = await sb.from("checkout_orders").select(
      "id,kind,amount_cents,status,created_at",
    ).order("created_at", { ascending: false }).limit(100);
    if (error) throw error;
    const { data: purchases, error: purchaseError } = await sb.from("purchases")
      .select("id,order_id").limit(100);
    if (purchaseError) throw purchaseError;
    const byOrder = Object.fromEntries(
      (purchases || []).map((row) => [row.order_id, row.id]),
    );
    if (target.isConnected) {
      target.innerHTML = (data || []).map((row) =>
        `<article class="content-card"><h2>${escape(row.kind)}</h2><p>$${
          (count(row.amount_cents) / 100).toFixed(2)
        } · ${escape(row.status)}</p><small>Receipt ${escape(row.id)}</small>${
          row.status === "paid" && byOrder[row.id]
            ? `<button class="btn btn-teal" onclick="downloadPurchase(${
              idArg(byOrder[row.id])
            },this)">Download</button>`
            : ""
        }</article>`
      ).join("") || "<p>No purchases yet.</p>";
    }
  } catch {
    if (target.isConnected) {
      target.textContent = "Receipts could not load. Please retry.";
    }
  }
}
async function downloadPurchase(id, button) {
  busy(button, true);
  try {
    const { url } = await platformRequest("purchases/" + id + "/download", {});
    const safe = publicURL(url);
    if (!safe) throw new Error("Invalid download destination");
    location.assign(safe);
  } catch (error) {
    actionError(error);
  } finally {
    busy(button, false);
  }
}
async function billingPortal() {
  try {
    const { url } = await platformRequest("billing-portal", {});
    const target = new URL(url);
    if (
      target.protocol !== "https:" || target.hostname !== "billing.stripe.com"
    ) throw new Error("Invalid billing destination");
    location.assign(target.href);
  } catch (error) {
    actionError(error);
  }
}
const servicesProfile = renderProfile;
renderProfile = function (p) {
  servicesProfile(p);
  p.querySelector(".pro-card")?.remove();
  p.insertAdjacentHTML(
    "beforeend",
    `<div class="content-list"><p>${count(S.coins)} coins${
      S.isPro ? " · Creator Pro active" : ""
    }</p><div class="action-row"><button class="btn btn-glass" onclick="showCoinsModal()">Coin packages</button><button class="btn btn-glass" onclick="navigate('purchases')">Receipts</button>${
      S.isPro
        ? '<button class="btn btn-glass" onclick="billingPortal()">Manage subscription</button>'
        : S.capabilities?.pro
        ? '<button class="btn btn-teal" onclick="upgradeCreatorPro()">Creator Pro — $19/month</button>'
        : ""
    }</div></div>`,
  );
};
let streamKit = null,
  streamHeartbeat = null,
  streamRenewal = null,
  currentStream = null,
  currentHost = false;
let zegoLoading = null;
function loadZego() {
  if (window.ZegoUIKitPrebuilt) return Promise.resolve();
  if (!zegoLoading) {
    zegoLoading = new Promise((resolve, reject) => {
      const script = document.createElement("script");
      script.src = "./vendor/zego-uikit-2.18.5.js";
      script.onload = resolve;
      script.onerror = () => {
        zegoLoading = null;
        reject(new Error("Streaming controls could not load."));
      };
      document.head.append(script);
    });
  }
  return zegoLoading;
}
renderLive = async function (p) {
  p.innerHTML =
    `<div class="page-hdr"><h1 class="page-title">Live</h1><p>Stream with purpose. Join a community broadcast or start your own.</p><button class="btn btn-pink" onclick="startGoLive()" ${
      !serviceReady("streaming") ? "disabled" : ""
    }>Go Live</button><p id="live-status" role="status">${
      serviceReady("streaming")
        ? "Loading broadcasts…"
        : "Streaming is awaiting provider configuration."
    }</p></div><div class="content-list" id="live-list"></div>`;
  if (!serviceReady("streaming")) return;
  try {
    const { data, error } = await sb.from("live_streams").select(
      "id,title,creator_id,profiles(display_name,username)",
    ).eq("status", "live").gt("lease_expires_at", new Date().toISOString())
      .limit(50);
    if (error) throw error;
    if (S.tab !== "live") return;
    p.querySelector("#live-status").textContent = data?.length
      ? "Live broadcasts"
      : "No broadcasts are live yet.";
    p.querySelector("#live-list").innerHTML = (data || []).map((row) =>
      `<article class="content-card"><h2>${escape(row.title)}</h2><p>${
        escape(
          row.profiles?.display_name || row.profiles?.username || "Creator",
        )
      }</p><button class="btn btn-teal" onclick="joinStream(${
        idArg(row.id)
      })">Join broadcast</button></article>`
    ).join("");
  } catch {
    const target = p.querySelector("#live-status");
    if (target) target.textContent = "Broadcasts could not load. Please retry.";
  }
};
startGoLive = function () {
  if (!serviceReady("streaming")) {
    showToast("Streaming is awaiting provider configuration.");
    return;
  }
  openDialog(
    "Start a Broadcast",
    `<form onsubmit="event.preventDefault();launchGoLive(this)">${
      field(
        "Broadcast title",
        "stream-title",
        "text",
        'maxlength="160" required',
      )
    }<p>Your camera and microphone are enabled only after you join through the streaming controls.</p><button class="btn btn-pink" type="submit">Prepare broadcast</button><p id="form-status" role="status"></p></form>`,
  );
};
launchGoLive = async function (form) {
  const button = form?.querySelector("[type=submit]");
  busy(button, true);
  try {
    const title = document.getElementById("stream-title").value.trim();
    const { stream_id } = await platformRequest("streams", { title });
    document.getElementById("customer-dialog")?.close();
    await joinStream(stream_id);
  } catch (error) {
    formStatus(error.message);
    actionError(error);
  } finally {
    busy(button, false);
  }
};
joinStream = async function (id) {
  if (!serviceReady("streaming")) {
    showToast("Streaming is awaiting provider configuration.");
    return;
  }
  try {
    const ticket = await platformRequest("streams/" + id + "/token", {});
    await loadZego();
    await cleanupStream();
    currentStream = id;
    currentHost = ticket.host;
    const p = document.getElementById("page");
    p.innerHTML =
      `<div class="page-hdr"><button class="btn btn-glass" onclick="leaveBroadcast()">${
        ticket.host ? "End broadcast" : "Leave broadcast"
      }</button><button class="btn btn-glass" onclick="shareStream()">Share broadcast</button></div><div id="zego-container" class="zego-container"></div><div class="content-list"><p id="stream-status" role="status">Use the streaming controls to join.</p>${
        !ticket.host
          ? `<div class="action-row">${
            GIFTS.map((g) =>
              `<button class="btn btn-glass btn-sm" onclick="sendGift(${
                idArg(g.name)
              },this)">${escape(g.icon)} ${
                escape(g.name)
              } · ${g.coins} coins</button>`
            ).join("")
          }</div>`
          : ""
      }</div>`;
    const z = window.ZegoUIKitPrebuilt;
    const kitToken = z.generateKitTokenForProduction(
      ticket.app_id,
      ticket.token,
      ticket.room_id,
      ticket.user_id,
      S.profile?.display_name || "Member",
    );
    streamKit = z.create(kitToken);
    const activeKit = streamKit;
    streamKit.joinRoom({
      container: document.getElementById("zego-container"),
      scenario: {
        mode: z.LiveStreaming,
        config: { role: ticket.host ? z.Host : z.Audience },
      },
      sharedLinks: [{
        name: "KingdomShift.Live",
        url: new URL(
          "?stream=" + id + "#live",
          location.origin + location.pathname,
        ).href,
      }],
      showPreJoinView: ticket.host,
      turnOnCameraWhenJoining: false,
      turnOnMicrophoneWhenJoining: false,
      showTextChat: true,
      onJoinRoom: () => {
        const status = document.getElementById("stream-status");
        if (status) status.textContent = "Connected to broadcast.";
      },
      onLiveStart: () => {
        if (ticket.host) {
          platformRequest("streams/" + id + "/activate", {}).catch(actionError);
        }
      },
      onLiveEnd: () => {
        if (ticket.host) leaveBroadcast();
      },
      onLeaveRoom: () => {
        if (streamKit === activeKit) leaveBroadcast();
      },
    });
    if (ticket.host) {
      streamHeartbeat = setInterval(
        () =>
          platformRequest("streams/" + id + "/heartbeat", {}).catch(() => {
            const status = document.getElementById("stream-status");
            if (status) {
              status.textContent =
                "Connection issue. Your broadcast may expire; rejoin to continue.";
            }
          }),
        30000,
      );
    }
    streamRenewal = setInterval(async () => {
      try {
        const fresh = await platformRequest("streams/" + id + "/token", {});
        const next = z.generateKitTokenForProduction(
          fresh.app_id,
          fresh.token,
          fresh.room_id,
          fresh.user_id,
          S.profile?.display_name || "Member",
        );
        if (!streamKit?.renewToken(next)) throw Error("renewal");
      } catch {
        const status = document.getElementById("stream-status");
        if (status) {
          status.textContent =
            "Session renewal failed. Leave and rejoin the broadcast.";
        }
      }
    }, 480000);
  } catch (error) {
    actionError(error);
    await cleanupStream();
    render();
  }
};
async function cleanupStream() {
  clearInterval(streamHeartbeat);
  clearInterval(streamRenewal);
  streamHeartbeat = null;
  streamRenewal = null;
  const kit = streamKit;
  streamKit = null;
  currentStream = null;
  currentHost = false;
  if (kit) kit.destroy();
}
let leavingBroadcast = false;
async function leaveBroadcast() {
  if (leavingBroadcast) return;
  leavingBroadcast = true;
  const id = currentStream, host = currentHost;
  try {
    if (host && id) await platformRequest("streams/" + id + "/end", {});
  } catch (error) {
    actionError(error);
  } finally {
    await cleanupStream();
    leavingBroadcast = false;
    navigate("live");
  }
}
endStream = leaveBroadcast;
async function shareStream() {
  if (!currentStream) return;
  const url = new URL(
    "?stream=" + currentStream + "#live",
    location.origin + location.pathname,
  );
  try {
    await navigator.clipboard.writeText(url.href);
    showToast("Broadcast link copied.");
  } catch {
    openDialog("Share Broadcast", `<p>${escape(url.href)}</p>`);
  }
}
sendGift = async function (gift, button) {
  if (!currentStream || currentHost) return;
  busy(button, true);
  try {
    S.coins = await call("send_live_gift", {
      stream: currentStream,
      gift,
      request_key: crypto.randomUUID(),
    });
    showToast(gift + " sent. " + S.coins + " coins remaining.");
  } catch (error) {
    actionError(error);
  } finally {
    busy(button, false);
  }
};
const servicesNavigate = navigate;
navigate = function (tab, subPage) {
  if (currentStream) {
    const id = currentStream, host = currentHost;
    cleanupStream();
    if (host) platformRequest("streams/" + id + "/end", {}).catch(() => {});
  }
  return servicesNavigate(tab, subPage);
};
const servicesRender = render;
render = function () {
  const p = document.getElementById("page");
  if (!S.subPage) {
    if (S.tab === "analytics") return renderAnalytics(p);
    if (S.tab === "catalog") return renderCatalog(p);
    if (S.tab === "purchases") return renderPurchases(p);
  }
  return servicesRender();
};
const servicesAdmin = renderAdmin;
renderAdmin = async function (p) {
  await servicesAdmin(p);
  if (S.tab !== "admin" || !p.querySelector(".content-list")) return;
  const section = document.createElement("section");
  section.className = "content-list";
  section.innerHTML =
    '<h2>Product reviews</h2><p role="status">Loading products…</p>';
  p.append(section);
  try {
    const products = await call("admin_catalog");
    if (!section.isConnected) return;
    section.innerHTML = "<h2>Product reviews</h2>" +
      ((products || []).map((row) =>
        `<article class="content-card"><h3>${escape(row.name)}</h3><p>${
          escape(row.description)
        }</p><p>$${
          count(row.price).toFixed(2)
        }</p><button class="btn btn-glass" onclick="previewProduct(${
          idArg(row.file_path)
        })">Review file</button><button class="btn btn-teal" onclick="adminDecision('catalog',${
          idArg(row.id)
        },'published')">Approve</button><button class="btn btn-glass" onclick="adminDecision('catalog',${
          idArg(row.id)
        },'removed')">Reject</button></article>`
      ).join("") || "<p>No products awaiting review.</p>");
  } catch {
    section.querySelector("p").textContent = "Product reviews could not load.";
  }
};
const contentAdminDecision = submitAdminDecision;
submitAdminDecision = async function (kind, id, decision, form) {
  if (kind !== "catalog") return contentAdminDecision(kind, id, decision, form);
  busy(form.querySelector("[type=submit]"), true);
  try {
    await call("moderate_shop_item", {
      item_key: id,
      decision,
      note: document.getElementById("review-note").value.trim(),
    });
    document.getElementById("customer-dialog").close();
    render();
  } catch (error) {
    formStatus(error.message);
    busy(form.querySelector("[type=submit]"), false);
  }
};
async function previewProduct(path) {
  try {
    const { data, error } = await sb.storage.from("shop-files").createSignedUrl(
      path,
      60,
      { download: true },
    );
    if (error) throw error;
    const url = publicURL(data.signedUrl);
    if (!url) throw Error("Invalid link");
    openDialog(
      "Review Product",
      `<p>Review this file before approving publication.</p><a class="btn btn-glass" href="${
        escape(url)
      }" target="_blank" rel="noopener noreferrer">Download review copy</a>`,
    );
  } catch (error) {
    actionError(error);
  }
}
let initialRouteOpened = false;
async function openInitialRoute() {
  if (
    initialRouteOpened || !S.user ||
    document.getElementById("app-view").style.display === "none" ||
    !S.capabilities
  ) return;
  initialRouteOpened = true;
  const stream = new URLSearchParams(location.search).get("stream");
  if (stream && /^ks_[0-9a-f-]{36}$/i.test(stream)) {
    navigate("live");
    if (serviceReady("streaming")) await joinStream(stream);
    return;
  }
  const hash = location.hash.slice(1);
  if (["purchases", "catalog", "analytics"].includes(hash)) {
    navigate(hash);
    return;
  }
  if (hash.startsWith("post/")) {
    const id = hash.slice(5);
    if (!validId(id)) return;
    try {
      const { data, error } = await sb.from("videos").select(
        "*,profiles(username,display_name,avatar,verified)",
      ).eq("id", id).eq("status", "published").maybeSingle();
      if (error || !data) {
        throw new Error("That post is unavailable or private.");
      }
      S.posts = [data];
      S.postsLoaded = true;
      navigate("feed");
    } catch (error) {
      actionError(error);
    }
  }
}
const servicesShowApp = showApp;
showApp = function () {
  servicesShowApp();
  openInitialRoute();
};
const servicesSignOut = handleSignOut;
handleSignOut = async function () {
  await cleanupStream();
  await servicesSignOut();
  initialRouteOpened = false;
};
window.addEventListener("DOMContentLoaded", async () => {
  await loadCapabilities();
  await openInitialRoute();
});
const operationsAdmin = renderAdmin;
renderAdmin = async function (p) {
  await operationsAdmin(p);
  if (S.tab !== "admin" || !p.querySelector(".content-list")) return;
  const section = document.createElement("section");
  section.className = "content-list";
  p.append(section);
  try {
    const data = await call("admin_operations");
    if (!section.isConnected) return;
    section.innerHTML = `<h2>Payment review</h2>${
      (data.incidents || []).map((row) =>
        `<article class="content-card"><p>${escape(row.kind)} · Order ${
          escape(row.order_id)
        }</p><p>Follow the payment incident runbook before restoring access or releasing money.</p></article>`
      ).join("") || "<p>No payment incidents.</p>"
    }<h2>Withdrawal review</h2>${
      (data.withdrawals || []).map((row) =>
        `<article class="content-card"><p>Account ${
          escape(row.creator_id)
        } · $${count(row.amount).toFixed(2)}</p><small>Request ${
          escape(row.id)
        }</small><p>Funds are reserved. Verify eligibility and settle through the documented payout process.</p></article>`
      ).join("") || "<p>No pending withdrawals.</p>"
    }<h2>Erasure processing</h2>${
      (data.deletions || []).map((row) =>
        `<article class="content-card"><p>Request ${escape(row.id)} · ${
          escape(row.status)
        }</p>${
          S.capabilities?.erasure_processing
            ? `<button class="btn btn-pink" onclick="confirmErasure(${
              idArg(row.id)
            })">Process approved erasure</button>`
            : "<p>Processing is disabled until the owner approves retention and settlement procedures.</p>"
        }</article>`
      ).join("") || "<p>No pending erasures.</p>"
    }`;
  } catch {
    section.textContent = "Operational queues could not load.";
  }
};
function confirmErasure(id) {
  openDialog(
    "Process Account Erasure",
    `<form onsubmit="event.preventDefault();processErasure(${
      idArg(id)
    },this)"><p>This removes account content, stored files, messages, and authentication. Required accounting records retain a pseudonymous reference. Financial obligations must be settled first.</p>${
      field(
        "Type the request ID to confirm",
        "erasure-confirmation",
        "text",
        "required",
      )
    }<button class="btn btn-pink" type="submit">Process erasure</button><p id="form-status" role="status"></p></form>`,
  );
}
async function processErasure(id, form) {
  if (document.getElementById("erasure-confirmation").value.trim() !== id) {
    formStatus("The request ID does not match.");
    return;
  }
  const button = form.querySelector("[type=submit]");
  busy(button, true);
  try {
    await platformRequest("admin/deletions/" + id + "/process", {});
    document.getElementById("customer-dialog").close();
    render();
    showToast("Account erasure completed.");
  } catch (error) {
    formStatus(error.message);
  } finally {
    busy(button, false);
  }
}
async function renderAnalytics(p) {
  p.innerHTML =
    '<div class="page-hdr"><h1 class="page-title">Creator Analytics</h1><p id="analytics-status" role="status">Loading your recorded activity…</p></div>';
  try {
    const data = await call("creator_analytics");
    if (S.tab !== "analytics") return;
    p.innerHTML =
      `<div class="page-hdr"><h1 class="page-title">Creator Analytics</h1><p>Recorded account activity and confirmed sales.</p></div><dl class="content-list">${
        [
          ["Published posts", data.posts],
          ["Likes", data.likes],
          ["Comments", data.comments],
          ["Followers", data.followers],
          ["Confirmed product sales", data.sales],
          [
            "Lifetime creator earnings",
            "$" + count(data.total_earned).toFixed(2),
          ],
        ].map(([label, value]) =>
          `<div class="content-card"><dt>${escape(label)}</dt><dd>${
            escape(value)
          }</dd></div>`
        ).join("")
      }</dl>`;
  } catch (error) {
    const target = p.querySelector("#analytics-status");
    if (target) target.textContent = error.message;
  }
}
const analyticsProfile = renderProfile;
renderProfile = function (p) {
  analyticsProfile(p);
  if (S.isPro) {
    p.insertAdjacentHTML(
      "beforeend",
      '<div class="content-list"><button class="btn btn-teal" onclick="navigate(\'analytics\')">Creator Analytics</button></div>',
    );
  }
};
