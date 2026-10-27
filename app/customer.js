/* Customer workflows. All writes are authorized by Supabase RLS or bounded RPCs. */
Object.assign(S, {
  postsLoaded: false,
  postsLoading: false,
  feedError: null,
  followStatus: {},
  messagePeer: null,
  capabilities: null,
});
NAV_ITEMS.splice(5, 0, {
  id: "studio",
  icon: "🎬",
  label: "Creator Studio",
  section: null,
});
NAV_ITEMS.push({
  id: "messages",
  icon: "💬",
  label: "Messages",
  section: "COMMUNITY",
}, { id: "notifications", icon: "🔔", label: "Notifications", section: null });
const escape = escapeHTML;
const idArg = jsArg;
const validId = (value) =>
  /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i
    .test(String(value));
const publicURL = (value) => {
  try {
    const u = new URL(value);
    return u.protocol === "https:" ? u.href : null;
  } catch {
    return null;
  }
};
async function call(name, args = {}) {
  if (!S.user) throw new Error("Sign in to continue.");
  const { data, error } = await sb.rpc(name, args);
  if (error) {
    throw new Error(
      error.message || "The request could not be completed. Please retry.",
    );
  }
  return data;
}
function actionError(error) {
  showToast(
    error?.message || "The request could not be completed. Please retry.",
  );
}
function openDialog(title, html) {
  document.getElementById("customer-dialog")?.remove();
  const dialog = document.createElement("dialog");
  dialog.id = "customer-dialog";
  dialog.innerHTML = `<div class="dialog-header"><h2 id="dialog-title">${
    escape(title)
  }</h2><button class="btn btn-glass" aria-label="Close dialog" onclick="document.getElementById('customer-dialog').close()">×</button></div>${html}`;
  dialog.setAttribute("aria-labelledby", "dialog-title");
  dialog.addEventListener("close", () => dialog.remove());
  document.body.append(dialog);
  dialog.showModal();
  return dialog;
}
function field(label, id, type = "text", extra = "") {
  return `<label class="label" for="${id}">${
    escape(label)
  }</label><input class="input" id="${id}" type="${type}" ${extra}>`;
}
function formStatus(message) {
  const el = document.getElementById("form-status");
  if (el) el.textContent = message;
}
function busy(button, value) {
  if (button) button.disabled = value;
}
async function syncSocialState() {
  const queries = [["video_likes", "video_id"], ["video_saves", "video_id"], [
    "follows",
    "following_id,status",
  ]];
  const results = await Promise.all(queries.map(async ([table, fields]) => {
    let query = sb.from(table).select(fields).limit(1000);
    if (table === "follows") query = query.eq("follower_id", S.user.id);
    const { data, error } = await query;
    if (error) throw error;
    return data || [];
  }));
  S.liked = Object.fromEntries(results[0].map((row) => [row.video_id, true]));
  S.saved = Object.fromEntries(results[1].map((row) => [row.video_id, true]));
  S.followStatus = Object.fromEntries(
    results[2].map((row) => [row.following_id, row.status]),
  );
}
const originalLoadProfile = loadProfile;
loadProfile = async function () {
  await originalLoadProfile();
  if (S.profile?.suspended) {
    throw new Error("This account is inactive. Contact support.");
  }
  const account = await call("get_my_account");
  Object.assign(S.profile, account || {});
  S.coins = count(account?.coins);
  S.isPro = !!account?.is_pro;
  await syncSocialState();
  if (S.profile?.role === "admin" && !NAV_ITEMS.some((n) => n.id === "admin")) {
    NAV_ITEMS.push({
      id: "admin",
      icon: "🔐",
      label: "Administration",
      section: "PLATFORM",
    });
  }
};
const originalSignOut = handleSignOut;
handleSignOut = async function () {
  await originalSignOut();
  Object.assign(S, {
    postsLoaded: false,
    postsLoading: false,
    feedError: null,
    followStatus: {},
    messagePeer: null,
  });
  const adminIndex = NAV_ITEMS.findIndex((n) => n.id === "admin");
  if (adminIndex >= 0) NAV_ITEMS.splice(adminIndex, 1);
};
fetchPosts = async function () {
  if (S.postsLoading) return;
  S.postsLoading = true;
  S.feedError = null;
  try {
    const { data, error } = S.savedOnly
      ? await sb.from("video_saves").select(
        "videos(*,profiles(username,display_name,avatar,verified))",
      ).order("created_at", { ascending: false }).limit(40)
      : await sb.from("videos").select(
        "*,profiles(username,display_name,avatar,verified)",
      ).eq("status", "published").order("created_at", { ascending: false })
        .limit(40);
    if (error) throw error;
    S.posts = S.savedOnly
      ? (data || []).map((row) => row.videos).filter(Boolean)
      : data || [];
    S.postsLoaded = true;
  } catch (error) {
    S.feedError = "The feed could not load. Please retry.";
  } finally {
    S.postsLoading = false;
  }
};
function retryFeed() {
  S.postsLoaded = false;
  S.feedError = null;
  render();
}
renderFeed = function (p) {
  if (!S.postsLoaded && !S.postsLoading && !S.feedError) {
    fetchPosts().then(() => {
      if (S.tab === "feed") render();
    });
  }
  p.innerHTML =
    `<div class="page-hdr"><h1 class="page-title">Community Feed</h1><p class="page-sub">Share faith, worship, and encouragement.</p><div class="action-row"><button class="btn btn-teal" onclick="navigate('studio')">Create a post</button><button class="btn btn-glass" onclick="S.savedOnly=!S.savedOnly;S.postsLoaded=false;S.posts=[];render()">${
      S.savedOnly ? "Show all posts" : "Saved posts"
    }</button></div></div>`;
  if (S.feedError) {
    p.innerHTML += `<p class="empty-state" role="alert">${
      escape(S.feedError)
    } <button class="btn btn-glass" onclick="retryFeed()">Retry</button></p>`;
    return;
  }
  if (!S.postsLoaded) {
    p.innerHTML += '<p class="empty-state" role="status">Loading posts…</p>';
    return;
  }
  const posts = S.posts.filter((post) => !S.savedOnly || S.saved[post.id]);
  if (!posts.length) {
    p.innerHTML +=
      '<p class="empty-state">No published posts yet. Create a post in Creator Studio; it will appear after review.</p>';
    return;
  }
  p.innerHTML += posts.map((post) =>
    `<article class="feed-post"><div class="fp-header"><div class="fp-av">${
      escape(post.profiles?.avatar || "👤")
    }</div><div class="grow"><button class="text-button" onclick="viewCreator(${
      idArg(post.creator_id)
    })">${
      escape(
        post.profiles?.display_name || post.profiles?.username || "Creator",
      )
    }</button><p class="fp-meta">${
      escape(post.category || "Faith")
    }</p></div><button class="btn btn-glass btn-sm" id="follow-${
      escape(post.id)
    }" onclick="toggleFollow(${idArg(post.creator_id)})">${
      escape(
        S.followStatus[post.creator_id] === "pending"
          ? "Requested"
          : S.followStatus[post.creator_id] === "accepted"
          ? "Following"
          : "Follow",
      )
    }</button></div><div class="post-body"><h2>${escape(post.title)}</h2><p>${
      escape(post.description || "")
    }</p></div>${
      post.file_path || publicURL(post.video_url)
        ? `<video class="post-video" id="media-${
          escape(post.id)
        }" controls playsinline preload="metadata" aria-label="${
          escape(post.title)
        }"></video><p id="media-status-${escape(post.id)}" role="status"></p>`
        : ""
    }<div class="fp-actions"><button class="btn btn-glass btn-sm" id="like-${
      escape(post.id)
    }" onclick="toggleLike(${idArg(post.id)})" aria-pressed="${!!S
      .liked[post.id]}">${S.liked[post.id] ? "❤️" : "🤍"} ${
      count(post.likes)
    }</button><button class="btn btn-glass btn-sm" onclick="showComments(${
      idArg(post.id)
    })">Comments</button><button class="btn btn-glass btn-sm" onclick="sharePost(${
      idArg(post.id)
    })">Share</button><button class="btn btn-glass btn-sm" id="save-${
      escape(post.id)
    }" aria-pressed="${!!S.saved[post.id]}" onclick="toggleSave(${
      idArg(post.id)
    })">${S.saved[post.id] ? "Saved" : "Save"}</button></div></article>`
  ).join("");
  for (const post of posts) loadPostMedia(post);
};
async function loadPostMedia(post) {
  const element = document.getElementById("media-" + post.id);
  if (!element) return;
  try {
    if (post.file_path) {
      const { data, error } = await sb.storage.from("videos").createSignedUrl(
        post.file_path,
        300,
      );
      if (error) throw error;
      if (element.isConnected) element.src = data.signedUrl;
    } else {
      const url = publicURL(post.video_url);
      if (url) element.src = url;
    }
  } catch {
    const status = document.getElementById("media-status-" + post.id);
    if (status) {
      status.textContent = "Media could not load. Refresh the page to retry.";
    }
  }
}
toggleLike = async function (id) {
  const button = document.getElementById("like-" + id);
  if (button?.disabled) return;
  busy(button, true);
  try {
    const liked = !S.liked[id];
    await call("set_video_like", { video: id, liked });
    S.liked[id] = liked;
    const post = S.posts.find((p) => p.id === id);
    if (post) post.likes = Math.max(0, count(post.likes) + (liked ? 1 : -1));
    if (button) {
      button.textContent = `${liked ? "❤️" : "🤍"} ${count(post?.likes)}`;
      button.setAttribute("aria-pressed", String(liked));
    }
  } catch (error) {
    actionError(error);
  } finally {
    busy(button, false);
  }
};
toggleSave = async function (id) {
  const button = document.getElementById("save-" + id);
  if (button?.disabled) return;
  busy(button, true);
  try {
    const saved = !S.saved[id];
    await call("set_video_saved", { video: id, saved });
    S.saved[id] = saved;
    if (button) {
      button.textContent = saved ? "Saved" : "Save";
      button.setAttribute("aria-pressed", String(saved));
    }
  } catch (error) {
    actionError(error);
  } finally {
    busy(button, false);
  }
};
toggleFollow = async function (creator) {
  if (creator === S.user?.id) {
    showToast("This is your profile.");
    return;
  }
  try {
    const status = await call("set_follow", {
      creator,
      following: !S.followStatus[creator] || S.followStatus[creator] === "none",
    });
    S.followStatus[creator] = status;
    showToast(
      status === "pending"
        ? "Follow request sent"
        : status === "accepted"
        ? "Following creator"
        : "Unfollowed creator",
    );
    if (S.tab === "feed" || S.tab === "creator") render();
  } catch (error) {
    actionError(error);
  }
};
async function sharePost(id) {
  const url = new URL(location.pathname, location.origin);
  url.hash = "post/" + id;
  try {
    await navigator.clipboard.writeText(url.href);
    showToast("Post link copied.");
  } catch {
    openDialog("Share this post", `<p>${escape(url.href)}</p>`);
  }
}
async function showComments(id) {
  const dialog = openDialog(
    "Comments",
    '<p role="status">Loading comments…</p>',
  );
  try {
    const { data, error } = await sb.from("comments").select(
      "id,body,created_at,profiles(display_name,username)",
    ).eq("video_id", id).order("created_at").limit(100);
    if (error) throw error;
    if (!dialog.isConnected) return;
    dialog.querySelector("p").outerHTML = `<div class="comment-list">${
      (data || []).map((comment) =>
        `<p><strong>${
          escape(
            comment.profiles?.display_name || comment.profiles?.username ||
              "Member",
          )
        }</strong><br>${escape(comment.body)}</p>`
      ).join("") || "<p>No comments yet.</p>"
    }</div><form onsubmit="event.preventDefault();submitComment(${
      idArg(id)
    },this)"><label class="label" for="comment-body">Your comment</label><textarea class="input" id="comment-body" maxlength="2000" required></textarea><button class="btn btn-teal" type="submit">Post comment</button><p id="form-status" role="status"></p></form>`;
  } catch (error) {
    dialog.querySelector("p").textContent =
      "Comments could not load. Please retry.";
  }
}
async function submitComment(id, form) {
  const button = form.querySelector("button[type=submit]");
  busy(button, true);
  try {
    await call("add_comment", {
      video: id,
      comment: document.getElementById("comment-body").value.trim(),
    });
    showComments(id);
  } catch (error) {
    formStatus(error.message);
  } finally {
    busy(button, false);
  }
}
async function renderStudio(p) {
  p.innerHTML =
    `<div class="page-hdr"><h1 class="page-title">Creator Studio</h1><p class="page-sub">Publish teaching, worship, or encouragement. Posts are reviewed before appearing publicly.</p><form id="content-form" onsubmit="event.preventDefault();submitContent(this)">${
      field("Title", "content-title", "text", 'maxlength="160" required')
    }<label class="label" for="content-description">Message</label><textarea class="input" id="content-description" maxlength="5000" required></textarea>${
      field(
        "Category",
        "content-category",
        "text",
        'maxlength="50" value="Faith" required',
      )
    }${
      field(
        "Optional video — MP4 or WebM, up to 100 MB",
        "content-file",
        "file",
        'accept="video/mp4,video/webm"',
      )
    }<button class="btn btn-teal" type="submit">Submit for review</button><p id="form-status" role="status"></p></form></div><div id="studio-content" class="content-list" role="status">Loading your posts…</div>`;
  const target = p.querySelector("#studio-content");
  try {
    const { data, error } = await sb.from("videos").select(
      "id,title,status,description,file_path",
    ).eq("creator_id", S.user.id).order("created_at", { ascending: false })
      .limit(100);
    if (error) throw error;
    if (!target.isConnected) return;
    target.innerHTML = (data || []).filter((row) =>
      row.status !== "removed"
    ).map((row) =>
      `<article class="content-card"><h2>${escape(row.title)}</h2><p>${
        escape(row.status)
      }</p><p>${
        escape(row.description || "")
      }</p><button class="btn btn-glass" onclick="editPost(${
        idArg(row.id)
      })">Edit post</button><button class="btn btn-glass" onclick="removePost(${
        idArg(row.id)
      })">Remove post</button></article>`
    ).join("") || "<p>You have not submitted any posts yet.</p>";
  } catch {
    if (target.isConnected) {
      target.textContent = "Your posts could not load. Please retry.";
    }
  }
}
async function submitContent(form) {
  const button = form.querySelector("[type=submit]");
  if (button.disabled) return;
  busy(button, true);
  let path = form.dataset.mediaPath || null;
  let uploaded = false;
  try {
    const file = document.getElementById("content-file").files[0];
    if (file) {
      if (
        !["video/mp4", "video/webm"].includes(file.type) ||
        file.size > 100 * 1024 * 1024
      ) throw new Error("Choose an MP4 or WebM video under 100 MB.");
      path = `${S.user.id}/${crypto.randomUUID()}.${
        file.type === "video/mp4" ? "mp4" : "webm"
      }`;
      uploaded = true;
      formStatus("Uploading video…");
      const { error } = await sb.storage.from("videos").upload(path, file, {
        contentType: file.type,
        upsert: false,
      });
      if (error) throw error;
    }
    formStatus("Submitting for review…");
    await call("save_content", {
      content_id: form.dataset.contentId || null,
      title: document.getElementById("content-title").value.trim(),
      description: document.getElementById("content-description").value.trim(),
      category: document.getElementById("content-category").value.trim(),
      media_path: path,
    });
    S.postsLoaded = false;
    showToast("Post submitted for review.");
    navigate("studio");
  } catch (error) {
    if (path && uploaded) {
      await sb.storage.from("videos").remove([path]).catch(() => {});
    }
    formStatus(error.message || "The post could not be submitted.");
  } finally {
    busy(button, false);
  }
}
async function removePost(id) {
  if (!confirm("Remove this post from the platform?")) return;
  try {
    await call("remove_content", { content_id: id });
    S.postsLoaded = false;
    navigate("studio");
  } catch (error) {
    actionError(error);
  }
}
async function renderNotifications(p) {
  p.innerHTML =
    '<div class="page-hdr"><h1 class="page-title">Notifications</h1><button class="btn btn-glass" onclick="markNotificationsRead()">Mark all read</button></div><div class="content-list" id="notification-list">Loading notifications…</div>';
  const target = p.querySelector("#notification-list");
  try {
    const { data, error } = await sb.from("notifications").select(
      "id,body,read_at,created_at",
    ).order("created_at", { ascending: false }).limit(100);
    if (error) throw error;
    if (target.isConnected) {
      target.innerHTML = (data || []).map((row) =>
        `<article class="content-card"><p>${escape(row.body)}</p><small>${
          row.read_at ? "Read" : "Unread"
        } · ${
          escape(new Date(row.created_at).toLocaleString())
        }</small></article>`
      ).join("") || "<p>No notifications yet.</p>";
    }
  } catch {
    if (target.isConnected) {
      target.textContent = "Notifications could not load. Please retry.";
    }
  }
}
async function markNotificationsRead() {
  try {
    const { error } = await sb.from("notifications").update({
      read_at: new Date().toISOString(),
    }).is("read_at", null);
    if (error) throw error;
    render();
  } catch (error) {
    actionError(error);
  }
}
async function renderMessages(p) {
  p.innerHTML =
    `<div class="page-hdr"><h1 class="page-title">Messages</h1><form onsubmit="event.preventDefault();submitMessage(this)">${
      field(
        "Recipient username",
        "message-recipient",
        "text",
        'pattern="[a-zA-Z0-9_]{3,64}" required',
      )
    }<label class="label" for="message-body">Your message</label><textarea class="input" id="message-body" maxlength="2000" required></textarea><button class="btn btn-teal" type="submit">Send message</button><p id="form-status" role="status"></p></form></div><div class="content-list" id="message-list">Loading messages…</div>`;
  const recipient = p.querySelector("#message-recipient");
  if (S.messagePeer) recipient.value = S.messagePeer;
  const target = p.querySelector("#message-list");
  try {
    const { data, error } = await sb.from("direct_messages").select(
      "id,sender_id,recipient_id,body,created_at,profiles!direct_messages_sender_id_fkey(display_name,username)",
    ).order("created_at", { ascending: false }).limit(100);
    if (error) throw error;
    if (target.isConnected) {
      target.innerHTML = (data || []).map((row) =>
        `<article class="content-card"><strong>${
          escape(
            row.sender_id === S.user.id
              ? "You"
              : row.profiles?.display_name || row.profiles?.username ||
                "Member",
          )
        }</strong><p>${escape(row.body)}</p><small>${
          escape(new Date(row.created_at).toLocaleString())
        }</small>${
          row.sender_id !== S.user.id
            ? `<button class="btn btn-glass btn-sm" onclick="blockMember(${
              idArg(row.sender_id)
            })">Block sender</button>`
            : ""
        }</article>`
      ).join("") || "<p>No messages yet.</p>";
    }
  } catch {
    if (target.isConnected) {
      target.textContent = "Messages could not load. Please retry.";
    }
  }
}
async function submitMessage(form) {
  const button = form.querySelector("[type=submit]");
  busy(button, true);
  try {
    const username = document.getElementById("message-recipient").value.trim()
      .toLowerCase();
    const { data, error } = await sb.from("profiles").select("id").eq(
      "username",
      username,
    ).maybeSingle();
    if (error || !data) throw new Error("That username could not be found.");
    await call("send_message", {
      recipient: data.id,
      message: document.getElementById("message-body").value.trim(),
    });
    S.messagePeer = username;
    showToast("Message sent.");
    render();
  } catch (error) {
    formStatus(error.message);
  } finally {
    busy(button, false);
  }
}
async function blockMember(id) {
  if (!confirm("Block messages and comments from this member?")) return;
  try {
    await call("set_user_block", { target: id, blocked: true });
    showToast("Member blocked.");
  } catch (error) {
    actionError(error);
  }
}
function viewCreator(id) {
  S.creatorId = id;
  navigate("creator");
}
async function renderCreator(p) {
  p.innerHTML = '<p class="empty-state">Loading creator…</p>';
  try {
    const { data, error } = await sb.from("profiles").select(
      "id,username,display_name,bio,avatar,followers,is_private",
    ).eq("id", S.creatorId).maybeSingle();
    if (error || !data) throw new Error("Creator unavailable.");
    if (S.tab !== "creator") return;
    p.innerHTML = `<div class="page-hdr"><h1 class="page-title">${
      escape(data.display_name || data.username)
    }</h1><p>@${escape(data.username)} · ${
      count(data.followers)
    } followers</p><p>${escape(data.bio || "")}</p><p>${
      data.is_private
        ? "Private content — follow requests require approval."
        : ""
    }</p><div class="action-row"><button class="btn btn-teal" onclick="toggleFollow(${
      idArg(data.id)
    })">${
      escape(
        S.followStatus[data.id] === "accepted"
          ? "Following"
          : S.followStatus[data.id] === "pending"
          ? "Requested"
          : "Follow",
      )
    }</button><button class="btn btn-glass" onclick="S.messagePeer=${
      idArg(data.username)
    };navigate('messages')">Message</button></div></div>`;
  } catch (error) {
    if (S.tab === "creator") p.textContent = error.message;
  }
}
function editProfile() {
  openDialog(
    "Edit Profile",
    `<form onsubmit="event.preventDefault();submitProfile(this)">${
      field(
        "Display name",
        "profile-display",
        "text",
        `value="${
          escape(S.profile?.display_name || "")
        }" maxlength="80" required`,
      )
    }${
      field(
        "Avatar emoji",
        "profile-avatar",
        "text",
        `value="${escape(S.profile?.avatar || "👤")}" maxlength="16" required`,
      )
    }<label class="label" for="profile-bio">Bio</label><textarea class="input" id="profile-bio" maxlength="1000">${
      escape(S.profile?.bio || "")
    }</textarea><button class="btn btn-teal" type="submit">Save profile</button><p id="form-status" role="status"></p></form>`,
  );
}
async function submitProfile(form) {
  const button = form.querySelector("[type=submit]");
  busy(button, true);
  try {
    const changes = {
      display_name: document.getElementById("profile-display").value.trim(),
      avatar: document.getElementById("profile-avatar").value.trim(),
      bio: document.getElementById("profile-bio").value.trim(),
    };
    const { error } = await sb.from("profiles").update(changes).eq(
      "id",
      S.user.id,
    );
    if (error) throw error;
    Object.assign(S.profile, changes);
    document.getElementById("sb-uname").textContent = changes.display_name;
    document.getElementById("sb-av").textContent = changes.avatar;
    document.getElementById("customer-dialog").close();
    render();
    showToast("Profile saved.");
  } catch (error) {
    formStatus(error.message);
  } finally {
    busy(button, false);
  }
}
function changePassword() {
  openDialog(
    "Change Password",
    `<form onsubmit="event.preventDefault();submitPassword(this)">${
      field(
        "New password",
        "new-password",
        "password",
        'minlength="8" autocomplete="new-password" required',
      )
    }<button class="btn btn-teal" type="submit">Update password</button><p id="form-status" role="status"></p></form>`,
  );
}
async function submitPassword(form) {
  const button = form.querySelector("[type=submit]");
  busy(button, true);
  try {
    const { error } = await sb.auth.updateUser({
      password: document.getElementById("new-password").value,
    });
    if (error) throw error;
    document.getElementById("customer-dialog").close();
    showToast("Password updated.");
  } catch (error) {
    formStatus(error.message);
  } finally {
    busy(button, false);
  }
}
function forgotPassword() {
  openDialog(
    "Reset Password",
    `<form onsubmit="event.preventDefault();submitPasswordReset(this)">${
      field(
        "Account email",
        "reset-email",
        "email",
        'autocomplete="email" required',
      )
    }<button class="btn btn-teal" type="submit">Send reset link</button><p id="form-status" role="status"></p></form>`,
  );
}
async function submitPasswordReset(form) {
  const button = form.querySelector("[type=submit]");
  busy(button, true);
  try {
    const { error } = await sb.auth.resetPasswordForEmail(
      document.getElementById("reset-email").value.trim(),
      { redirectTo: new URL(location.pathname, location.origin).href },
    );
    if (error) throw error;
    formStatus(
      "If this email has an account, a password-reset link will arrive shortly.",
    );
  } catch {
    formStatus("The reset request could not be sent. Please retry.");
  } finally {
    busy(button, false);
  }
}
const originalAuthForm = renderAuthForm;
renderAuthForm = function () {
  originalAuthForm();
  const host = document.getElementById("auth-form");
  host.insertAdjacentHTML(
    "beforeend",
    S.authMode === "login"
      ? '<button class="text-button" onclick="forgotPassword()">Forgot password?</button>'
      : '<label class="consent"><input id="accept-terms" type="checkbox"> I am at least 13 and agree to the <a href="#terms">Terms of Service</a> and <a href="./privacy.html">Privacy Policy</a>.</label>',
  );
};
const originalSignUp = handleSignUp;
handleSignUp = async function () {
  if (!document.getElementById("accept-terms")?.checked) {
    showAuthError("Please confirm your age and acceptance of the terms.");
    return;
  }
  return originalSignUp();
};
sb?.auth.onAuthStateChange((event) => {
  if (event === "PASSWORD_RECOVERY") setTimeout(changePassword, 0);
});
const originalProfile = renderProfile;
renderProfile = function (p) {
  originalProfile(p);
  p.querySelector(".profile-edit-btn").onclick = editProfile;
  p.insertAdjacentHTML(
    "beforeend",
    '<div class="content-list"><button class="btn btn-teal" onclick="navigate(\'studio\')">Open Creator Studio</button></div>',
  );
};
const originalSettings = renderSettings;
renderSettings = function (p) {
  originalSettings(p);
  for (const row of p.querySelectorAll(".sr")) {
    const label = row.querySelector(".sr-label")?.textContent;
    if (label === "Edit Profile") row.onclick = editProfile;
    else if (label === "Change Password") row.onclick = changePassword;
    else if (label === "Contact Support") {
      row.onclick = () => {
        location.href = "mailto:kingdomshiftmedia@gmail.com";
      };
    } else if (label === "About") {
      row.onclick = () =>
        openDialog(
          "KingdomShift.Live",
          "<p>Equip · Empower · Expand the Kingdom.</p>",
        );
    } else if (label === "Email") {
      row.onclick = () =>
        showToast(S.user?.email || "Sign in to manage your account.");
    }
  }
};
const originalPrivacySettings = renderPrivacySettings;
renderPrivacySettings = function (p) {
  originalPrivacySettings(p);
  const description = p.querySelector(".sr-desc");
  if (description) {
    description.textContent = "Only accepted followers can see your content.";
  }
  p.insertAdjacentHTML(
    "beforeend",
    '<div class="content-list"><h2>Follow requests</h2><div id="follow-requests">Loading requests…</div></div>',
  );
  call("get_follow_requests").then((rows) => {
    const target = document.getElementById("follow-requests");
    if (target) {
      target.innerHTML = (rows || []).map((row) =>
        `<article class="content-card"><p>${
          escape(row.display_name || row.username)
        }</p><button class="btn btn-teal" onclick="reviewFollow(${
          idArg(row.follower_id)
        },true)">Accept</button><button class="btn btn-glass" onclick="reviewFollow(${
          idArg(row.follower_id)
        },false)">Decline</button></article>`
      ).join("") || "<p>No pending requests.</p>";
    }
  }).catch(() => {
    const target = document.getElementById("follow-requests");
    if (target) target.textContent = "Requests could not load.";
  });
};
async function reviewFollow(id, accept) {
  try {
    await call("review_follow", { follower: id, accept });
    render();
  } catch (error) {
    actionError(error);
  }
}
renderDeleteAccount = function (p) {
  p.innerHTML =
    `<div class="page-hdr"><h1 class="page-title">Delete Account</h1><p>Request deletion of your account and associated personal data. Submitting deactivates your account and hides your content immediately. Support will process removal within 30 days, subject to required financial record retention.</p><form onsubmit="event.preventDefault();submitDeletion(this)"><label class="consent"><input id="confirm-deletion" type="checkbox" required> I understand my account will be deactivated and I want to request deletion.</label><button class="btn btn-pink" type="submit">Request account deletion</button><p id="form-status" role="status"></p></form><p>Need help? <a href="mailto:kingdomshiftmedia@gmail.com?subject=Account%20Deletion%20Request">Email support</a>.</p></div>`;
};
async function submitDeletion(form) {
  const button = form.querySelector("[type=submit]");
  if (!document.getElementById("confirm-deletion").checked) return;
  busy(button, true);
  try {
    const id = await call("request_account_deletion");
    await handleSignOut();
    showAuthError(
      "Deletion request recorded: " + id +
        ". Your account is deactivated. Support will process removal within 30 days.",
      true,
    );
  } catch (error) {
    formStatus(error.message);
  } finally {
    busy(button, false);
  }
}
renderAdmin = async function (p) {
  p.innerHTML =
    '<div class="page-hdr"><h1 class="page-title">Administration</h1><p id="admin-status" role="status">Loading authorized dashboard…</p></div>';
  try {
    const data = await call("admin_overview");
    if (S.tab !== "admin") return;
    p.innerHTML =
      `<div class="page-hdr"><h1 class="page-title">Administration</h1><p>${
        count(data.profiles)
      } accounts · ${
        count(data.published)
      } published posts</p></div><div class="content-list"><h2>Content awaiting review</h2>${
        (data.content || []).map((row) =>
          `<article class="content-card"><h3>${escape(row.title)}</h3><p>${
            escape(row.description || "")
          }</p>${
            row.file_path
              ? `<button class="btn btn-glass" onclick="previewModerationMedia(${
                idArg(row.id)
              },${idArg(row.file_path)})">Preview media</button>`
              : ""
          }<button class="btn btn-teal" onclick="adminDecision('content',${
            idArg(row.id)
          },'published')">Approve</button><button class="btn btn-glass" onclick="adminDecision('content',${
            idArg(row.id)
          },'removed')">Reject</button></article>`
        ).join("") || "<p>No content awaiting review.</p>"
      }<h2>Reports</h2>${
        (data.reports || []).map((row) =>
          `<article class="content-card"><p>${escape(row.type)} · ${
            escape(row.details || "No details recorded")
          }</p>${
            publicURL(row.content_url)
              ? `<a href="${
                escape(publicURL(row.content_url))
              }" target="_blank" rel="noopener noreferrer">Reported content</a>`
              : ""
          }<p>Reported account: ${
            escape(row.reported_id || "See content link")
          }</p><button class="btn btn-teal" onclick="adminDecision('report',${
            idArg(row.id)
          },'resolved')">Resolve</button><button class="btn btn-glass" onclick="adminDecision('report',${
            idArg(row.id)
          },'dismissed')">Dismiss</button></article>`
        ).join("") || "<p>No pending reports.</p>"
      }<h2>Deletion requests</h2>${
        (data.deletions || []).map((row) =>
          `<article class="content-card"><p>Request ${
            escape(row.id)
          }</p><p>Account ${escape(row.user_id)} · ${
            escape(row.status)
          }</p><p>Process through the documented deletion procedure; do not mark complete until personal data and authentication have been removed.</p></article>`
        ).join("") || "<p>No pending requests.</p>"
      }<h2>Account moderation</h2><form onsubmit="event.preventDefault();submitSuspension(this)">${
        field("Account ID", "suspend-id", "text", "required")
      }${
        field(
          "Reason",
          "suspend-note",
          "text",
          'minlength="3" maxlength="1000" required',
        )
      }<label class="consent"><input id="suspend-value" type="checkbox" checked> Suspend account (uncheck to restore)</label><button class="btn btn-pink" type="submit">Apply account decision</button><p id="form-status" role="status"></p></form></div>`;
  } catch (error) {
    p.querySelector("#admin-status").textContent =
      "Administrator access could not be verified. " + error.message;
  }
};
async function previewModerationMedia(id, path) {
  try {
    const { data, error } = await sb.storage.from("videos").createSignedUrl(
      path,
      300,
    );
    if (error) throw error;
    openDialog(
      "Media preview",
      `<video class="post-video" controls playsinline src="${
        escape(data.signedUrl)
      }"></video>`,
    );
  } catch (error) {
    actionError(error);
  }
}
function adminDecision(kind, id, decision) {
  openDialog(
    "Record review decision",
    `<form onsubmit="event.preventDefault();submitAdminDecision(${
      idArg(kind)
    },${idArg(id)},${idArg(decision)},this)">${
      field(
        "Review note",
        "review-note",
        "text",
        'minlength="3" maxlength="1000" required',
      )
    }<button class="btn btn-teal" type="submit">Confirm ${
      escape(decision)
    }</button><p id="form-status" role="status"></p></form>`,
  );
}
async function submitAdminDecision(kind, id, decision, form) {
  const button = form.querySelector("[type=submit]");
  busy(button, true);
  try {
    await call(kind === "content" ? "moderate_content" : "resolve_report", {
      [kind === "content" ? "content_id" : "report_id"]: id,
      decision,
      note: document.getElementById("review-note").value.trim(),
    });
    document.getElementById("customer-dialog").close();
    S.postsLoaded = false;
    render();
  } catch (error) {
    formStatus(error.message);
  } finally {
    busy(button, false);
  }
}
async function submitSuspension(form) {
  busy(form.querySelector("[type=submit]"), true);
  try {
    const member = document.getElementById("suspend-id").value.trim();
    if (!validId(member)) throw new Error("Enter a valid account ID.");
    await call("suspend_member", {
      member,
      suspended: document.getElementById("suspend-value").checked,
      note: document.getElementById("suspend-note").value.trim(),
    });
    formStatus("Account decision recorded.");
  } catch (error) {
    formStatus(error.message);
  } finally {
    busy(form.querySelector("[type=submit]"), false);
  }
}
const originalRender = render;
render = function () {
  const p = document.getElementById("page");
  if (!p) return;
  const extra = {
    studio: renderStudio,
    messages: renderMessages,
    notifications: renderNotifications,
    creator: renderCreator,
  };
  if (!S.subPage && extra[S.tab]) return extra[S.tab](p);
  return originalRender();
};
document.querySelector('[aria-label="Notifications unavailable"]').onclick =
  () => navigate("notifications");
document.querySelector('[aria-label="Notifications unavailable"]').setAttribute(
  "aria-label",
  "Notifications",
);
document.querySelector('[aria-label="Messaging unavailable"]').onclick = () =>
  navigate("messages");
document.querySelector('[aria-label="Messaging unavailable"]').setAttribute(
  "aria-label",
  "Messages",
);
// Search real creator identities; no fabricated accounts or simulated follows.
renderSearch = function (p) {
  p.innerHTML =
    '<div class="page-hdr"><h1 class="page-title">Discover Creators</h1><label class="label" for="search-input">Search by username or display name</label><input class="input" id="search-input" placeholder="Search creators…" oninput="searchContent(this.value)"></div><div class="content-list" id="search-results" role="status">Enter at least two characters.</div>';
};
searchContent = async function (value) {
  const target = document.getElementById("search-results");
  const query = String(value || "").replace(/[^a-zA-Z0-9_ ]/g, "").trim().slice(
    0,
    80,
  );
  S.searchQuery = query;
  if (query.length < 2) {
    if (target) target.textContent = "Enter at least two characters.";
    return;
  }
  try {
    const { data, error } = await sb.from("profiles").select(
      "id,username,display_name,avatar,verified,is_private",
    ).or(`username.ilike.%${query}%,display_name.ilike.%${query}%`).limit(20);
    if (error) throw error;
    if (!target?.isConnected || S.searchQuery !== query) return;
    target.innerHTML = (data || []).map((row) =>
      `<article class="content-card"><p>${escape(row.avatar || "👤")} ${
        escape(row.display_name || row.username)
      } ${row.verified ? "✓" : ""}</p><p>@${escape(row.username)} ${
        row.is_private ? "· Private content" : ""
      }</p><button class="btn btn-glass" onclick="viewCreator(${
        idArg(row.id)
      })">View creator</button></article>`
    ).join("") || "<p>No creators found.</p>";
  } catch {
    if (target?.isConnected) {
      target.textContent = "Search could not load. Please retry.";
    }
  }
};
async function editPost(id) {
  try {
    const { data, error } = await sb.from("videos").select(
      "id,title,description,category,file_path",
    ).eq("id", id).eq("creator_id", S.user.id).maybeSingle();
    if (error || !data) throw new Error("Post unavailable.");
    const form = document.getElementById("content-form");
    form.dataset.contentId = data.id;
    form.dataset.mediaPath = data.file_path || "";
    form.querySelector("#content-title").value = data.title;
    form.querySelector("#content-description").value = data.description || "";
    form.querySelector("#content-category").value = data.category || "Faith";
    form.querySelector("[type=submit]").textContent = "Resubmit for review";
    form.scrollIntoView({ block: "start" });
    form.querySelector("#content-title").focus();
  } catch (error) {
    actionError(error);
  }
}
submitReport = async function () {
  const status = document.getElementById("report-status"),
    button = document.getElementById("report-submit"),
    form = document.getElementById("report-form");
  if (!S.user) {
    status.textContent = "Please sign in to submit a report, or email support.";
    return;
  }
  if (button.disabled || !form.reportValidity()) return;
  busy(button, true);
  try {
    await call("submit_safety_report", {
      content_url: document.getElementById("report-url").value.trim(),
      details: document.getElementById("report-details").value.trim(),
      concern: document.getElementById("report-type").value,
    });
    form.reset();
    status.textContent = "Report received for review.";
  } catch {
    status.textContent =
      "Your report could not be sent. Please retry or email kingdomshiftmedia@gmail.com.";
  } finally {
    busy(button, false);
  }
};
const extendedPrivacy = renderPrivacySettings;
renderPrivacySettings = function (p) {
  extendedPrivacy(p);
  p.insertAdjacentHTML(
    "beforeend",
    `<div class="content-list"><h2>Message privacy</h2><button class="btn btn-glass" role="switch" aria-checked="${
      S.privacySettings.allowMessages !== false
    }" onclick="togglePrivacy('allowMessages')">Allow messages</button><h2>Blocked members</h2><div id="blocked-members">Loading blocked members…</div></div>`,
  );
  sb.from("user_blocks").select(
    "blocked_id,profiles!user_blocks_blocked_id_fkey(username,display_name)",
  ).limit(100).then(({ data, error }) => {
    const target = document.getElementById("blocked-members");
    if (!target) return;
    if (error) {
      target.textContent = "Blocked members could not load.";
      return;
    }
    target.innerHTML = (data || []).map((row) =>
      `<article class="content-card"><p>${
        escape(
          row.profiles?.display_name || row.profiles?.username ||
            row.blocked_id,
        )
      }</p><button class="btn btn-glass" onclick="unblockMember(${
        idArg(row.blocked_id)
      })">Unblock</button></article>`
    ).join("") || "<p>No blocked members.</p>";
  });
};
async function unblockMember(id) {
  try {
    await call("set_user_block", { target: id, blocked: false });
    render();
  } catch (error) {
    actionError(error);
  }
}
const customerNavigate = navigate;
navigate = function (tab, subPage) {
  if (
    !S.user && !["feed", "search", "creator"].includes(tab) &&
    ![
      "privacy_policy",
      "terms_of_service",
      "creator_agreement",
      "child_safety",
      "delete_account",
    ].includes(subPage)
  ) {
    S.pendingTab = tab;
    showAuth("login");
    return;
  }
  return customerNavigate(tab, subPage);
};
const customerShowApp = showApp;
showApp = function () {
  customerShowApp();
  if (S.user && S.pendingTab) {
    const tab = S.pendingTab;
    S.pendingTab = null;
    navigate(tab);
  }
};
function openCommunity() {
  S.tab = "feed";
  S.subPage = null;
  showApp();
}
const customerAuthForm = renderAuthForm;
renderAuthForm = function () {
  customerAuthForm();
  document.getElementById("auth-form").insertAdjacentHTML(
    "beforeend",
    '<button class="text-button" onclick="openCommunity()">Explore public posts</button>',
  );
};
