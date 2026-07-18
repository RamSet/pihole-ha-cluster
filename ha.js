/* Pi-hole HA Cluster - Native Web UI JavaScript
 * Uses same-origin ha-api proxy to avoid cross-origin/mixed-content issues
 */
$(function () {
    "use strict";

    var $haCfg = $("#ha-config");
    var NODES = $haCfg.length ? JSON.parse($haCfg.attr("data-nodes")) : (window.HA_NODES || []);

    var GATEWAY_IP = ($haCfg.length ? $haCfg.attr("data-gateway") : window.HA_GATEWAY) || "";

    // Build PROMOTE_IDS dynamically from NODES
    var PROMOTE_IDS = {};
    NODES.forEach(function (n) {
        PROMOTE_IDS[n.ip] = "promote-" + n.ip.replace(/\./g, "_");
    });

    // Build MASTER_IDS dynamically from NODES
    var MASTER_IDS = { "auto": "master-auto" };
    NODES.forEach(function (n) {
        MASTER_IDS[n.ip] = "master-" + n.ip.replace(/\./g, "_");
    });

    var API = "ha-api";

    // Escape untrusted values before inserting into HTML (text or double-quoted attribute).
    function escapeHtml(s) {
        return String(s == null ? "" : s).replace(/[&<>"']/g, function (c) {
            return { "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c];
        });
    }

    var statusData = null;
    var prevReach = {};        // per-node last-seen reachability (for redshift/blueshift)
    var syncCfg = null;
    var syncManifest = null;
    var notifyCfg = null;
    var masterCfg = null;
    var vipCfg = null;
    var haCfg = null;
    var authPending = {};  // track nodes with pending auth saves

    // Initial polls
    pollStatus();
    pollSync();
    pollNotify();
    pollMaster();
    pollVip();
    pollHa();
    pollVersion();  // once on load; the backend caches the upstream check daily

    // Periodic polling
    setInterval(pollStatus, 5000);
    setInterval(pollSync, 15000);
    setInterval(pollNotify, 15000);
    setInterval(pollMaster, 5000);
    setInterval(pollVip, 10000);
    setInterval(pollHa, 5000);

    // ---- Event bindings (CSP-safe, no inline onclick) ----
    $(document).on("click", "#toggle-ha", function () { window.haHaToggle(); });
    $(document).on("click", "#toggle-vip", function () { window.haVipToggle(); });
    $(document).on("click", "#toggle-enabled", function () { window.haToggle("enabled"); });
    $(document).on("click", "#toggle-gravity", function () { window.haToggle("gravity"); });
    $(document).on("click", "#toggle-dhcp", function () { window.haToggle("dhcp"); });
    $(document).on("click", "#toggle-dns", function () { window.haToggle("dns"); });
    $(document).on("click", "#toggle-settings", function () { window.haToggle("settings"); });
    $(document).on("click", "#toggle-notify", function () { window.haNotifyToggle(); });
    $(document).on("click", "#sync-now-btn", function () { window.haSyncNow(); });
    $(document).on("change", "#sync-interval", function () { window.haSyncInterval($(this).val()); });
    $(document).on("click", "#notify-save-btn", function () { window.haNotifySave(); });
    $(document).on("click", "#notify-test-btn", function () { window.haNotifyTest(); });
    $(document).on("click", "#master-auto", function () { window.haSetMaster("auto"); });
    $(document).on("click", ".ha-re-enable-btn", function () { window.haHaToggle(); });
    $(document).on("click", ".ha-auth-save", function () {
        window.haSetAuth($(this).data("ip"), $(this).data("idx"));
    });
    $(document).on("click", ".prio-up", function () {
        window.haMovePrio($(this).data("idx"), -1);
    });
    $(document).on("click", ".prio-down", function () {
        window.haMovePrio($(this).data("idx"), 1);
    });
    NODES.forEach(function (n) {
        var ipId = n.ip.replace(/\./g, "_");
        $(document).on("click", "#master-" + ipId, function () { window.haSetMaster(n.ip); });
        $(document).on("click", "#promote-" + ipId, function () { window.haPromote(n.ip); });
    });

    // ---- Status polling ----

    function pollStatus() {
        $.ajax({
            url: API + "?action=status",
            timeout: 4000,
            dataType: "json"
        })
        .done(function (data) {
            if (data && !data.error) {
                statusData = data;
                $("#ha-error").hide();
            } else {
                statusData = null;
                $("#ha-error").show();
            }
        })
        .fail(function () {
            statusData = null;
            $("#ha-error").show();
        })
        .always(function () {
            renderOverview();
            renderHealth();
        });
    }

    // ---- Sync polling ----
    // Fire each AJAX independently - each calls renderSync on completion
    // so we never miss an update due to $.when() race conditions

    function pollSync() {
        $.ajax({
            url: API + "?action=sync-config",
            timeout: 4000,
            dataType: "json"
        })
        .done(function (data) {
            syncCfg = (data && !data.error) ? data : null;
        })
        .fail(function () { syncCfg = null; })
        .always(renderSync);

        $.ajax({
            url: API + "?action=sync-manifest",
            timeout: 4000,
            dataType: "json"
        })
        .done(function (data) {
            syncManifest = (data && !data.error) ? data : null;
        })
        .fail(function () { syncManifest = null; })
        .always(renderSync);
    }

    // ---- Render: Overview cards ----

    // Render a node timestamp (UTC "...Z") in the viewer's local time, so the
    // display is correct regardless of the node's own timezone. Falls back to
    // the raw string for anything unparseable (e.g. legacy naive timestamps).
    function fmtTime(ts) {
        if (!ts) return "—";
        var d = new Date(ts);
        return isNaN(d.getTime()) ? ts : d.toLocaleString();
    }

    function renderOverview() {
        // Gateway + timestamp
        var gwOk = !!(statusData && statusData.gateway);
        var allReachable = !!(statusData && statusData.peers);
        if (statusData) {
            $("#gw-status").html(
                '<i class="fa fa-circle" style="color:' +
                (gwOk ? "#00a65a" : "#dd4b39") + '; font-size:10px"></i> ' +
                "Gateway " + GATEWAY_IP + ": " +
                '<strong>' + (gwOk ? "Reachable" : "UNREACHABLE") + '</strong>'
            );
            $("#ha-timestamp").text("Last check: " + fmtTime(statusData.timestamp));
        } else {
            $("#gw-status").html(
                '<i class="fa fa-circle" style="color:#aaa; font-size:10px"></i> Gateway: No data'
            );
            $("#ha-timestamp").text("");
        }

        // Node cards
        $.each(NODES, function (i, node) {
            var $box = $("#node-box-" + i);
            var $status = $("#node-status-" + i);
            var $stats = $("#node-stats-" + i);
            var $footer = $("#node-footer-" + i);

            if (!statusData || !statusData.peers) {
                $box.attr("class", "small-box bg-aqua no-user-select");
                $status.text("---");
                $stats.html("&nbsp;");
                $footer.html(node.ip + ' <i class="fa fa-arrow-circle-right"></i>');
                return;
            }

            var peer = statusData.peers[node.ip];
            var isLocal = node.ip === statusData.node.ip;
            var dhcpActive = isLocal
                ? statusData.node.dhcp_active
                : (peer && peer.dhcp === true);
            var reachable = peer && peer.ping === true;
            if (!reachable) allReachable = false;
            // Doppler flavor: a node moving away (down) is redshifted; one that
            // was gone and is back (approaching) is blueshifted.
            var doppler = "";
            if (!reachable) {
                doppler = '<span class="text-muted" style="font-style:italic" title="receding - node unreachable">redshifted</span>';
            } else if (prevReach[node.ip] === false) {
                doppler = '<span style="color:#3c8dbc;font-style:italic" title="returning - node recovered">blueshifted</span>';
            }
            prevReach[node.ip] = reachable;
            var vipEnabled = statusData.node.vip_enabled;
            var vipHeld = isLocal && vipEnabled && statusData.node.vip_held;

            var manualMaster = statusData.dhcp_master && statusData.dhcp_master !== "auto";
            var isDesignatedMaster = manualMaster && statusData.dhcp_master === node.ip;

            var bgClass;
            if (!reachable) {
                bgClass = "bg-red";
                $status.text("UNREACHABLE");
            } else if (dhcpActive && isDesignatedMaster) {
                bgClass = "bg-green";
                $status.text("MANUAL MASTER");
            } else if (dhcpActive && node.priority === 1 && !manualMaster) {
                bgClass = "bg-green";
                $status.text("DHCP Active");
            } else if (dhcpActive) {
                bgClass = "bg-yellow";
                $status.text(manualMaster ? "Failover (master down)" : "Failover Active");
            } else {
                bgClass = "bg-aqua";
                $status.text(isDesignatedMaster ? "MASTER (activating...)" : "Standby");
            }

            $box.attr("class", "small-box " + bgClass + " no-user-select");

            // Stats line: clients and leases (+ Doppler flavor)
            var statParts = [];
            if (peer && typeof peer.clients === "number") {
                statParts.push(peer.clients + " clients");
            }
            if (peer && typeof peer.leases === "number") {
                statParts.push(peer.leases + " leases");
            }
            if (doppler) statParts.push(doppler);
            $stats.html(statParts.length ? statParts.join(" &bull; ") : "&nbsp;");

            var footerParts = [node.ip];
            if (isLocal) footerParts.push("(this node)");
            if (vipHeld) footerParts.push("VIP: " + statusData.node.vip);
            $footer.html(
                footerParts.join(" &bull; ") +
                ' <i class="fa fa-arrow-circle-right"></i>'
            );

            // Leave button - only on local node's card, only if >1 node
            var $leaveBtn = $("#leave-btn-" + i);
            if (isLocal && NODES.length > 1) {
                if (!$leaveBtn.length) {
                    $box.find(".inner").append(
                        '<button id="leave-btn-' + i + '" class="btn btn-xs btn-danger" ' +
                        'style="position:absolute;top:8px;right:8px;z-index:10" ' +
                        'data-ip="' + node.ip + '">Leave Cluster</button>'
                    );
                    $("#leave-btn-" + i).on("click", function () {
                        var ip = $(this).data("ip");
                        if (!confirm("Remove this node (" + ip + ") from the cluster?")) return;
                        $.ajax({
                            url: API + "?action=leave&ip=" + encodeURIComponent(ip),
                            timeout: 10000,
                            dataType: "json"
                        }).done(function (r) {
                            if (r.ok) {
                                alert("Node removed from cluster. This page will stop updating.");
                                location.reload();
                            } else {
                                alert("Error: " + (r.error || "unknown"));
                            }
                        }).fail(function () {
                            alert("Failed to contact HA API.");
                        });
                    });
                }
            } else {
                $leaveBtn.remove();
            }
        });

        // System state (astrophysics flavor): equilibrium when balanced,
        // perturbation when a node is redshifted, orbital decay when this node
        // can't see the gateway (isolated). Colour carries the severity.
        var $eq = $("#ha-equilibrium");
        if (!statusData) {
            $eq.text("");
        } else if (!gwOk) {
            $eq.html('<span style="color:#dd4b39" title="gateway unreachable - this node is isolated">Orbital decay</span>');
        } else if (!allReachable) {
            $eq.html('<span style="color:#f39c12" title="a node is redshifted - failover is holding">Gravitational perturbation</span>');
        } else {
            $eq.html('<span style="color:#00a65a" title="all nodes healthy and in orbit">Gravitational equilibrium</span>');
        }
    }

    // ---- Render: Health check tables ----

    function renderHealth() {
        $.each(NODES, function (i, node) {
            var $tbody = $("#health-body-" + i);

            if (!statusData || !statusData.peers || !statusData.peers[node.ip]) {
                $tbody.html(
                    '<tr><td colspan="2" class="text-center text-muted">No data</td></tr>'
                );
                return;
            }

            var peer = statusData.peers[node.ip];
            var checks = [
                { name: "Ping", val: peer.ping },
                { name: "DNS :53", val: peer.dns }
            ];

            var html = "";
            $.each(checks, function (_, c) {
                var icon, label, color;
                if (c.val === true) {
                    color = "#00a65a"; icon = "fa-check-circle"; label = "OK";
                } else if (c.val === false) {
                    color = "#dd4b39"; icon = "fa-times-circle"; label = "FAIL";
                } else {
                    color = "#aaa"; icon = "fa-minus-circle"; label = "N/A";
                }
                html += '<tr><td>' + c.name + '</td>' +
                    '<td><i class="fa ' + icon + '" style="color:' + color + '"></i> ' +
                    '<span style="color:' + color + '">' + label + '</span></td></tr>';
            });

            // Pi-hole API row: distinguish auth denied from actual failure
            var aIcon, aLabel, aColor;
            if (peer.api === true) {
                aColor = "#00a65a"; aIcon = "fa-check-circle"; aLabel = "OK";
            } else if (peer.auth === "denied") {
                aColor = "#f0ad4e"; aIcon = "fa-lock"; aLabel = "Locked";
            } else if (peer.api === false) {
                aColor = "#dd4b39"; aIcon = "fa-times-circle"; aLabel = "FAIL";
            } else {
                aColor = "#aaa"; aIcon = "fa-minus-circle"; aLabel = "N/A";
            }
            html += '<tr><td>Pi-hole API</td>' +
                '<td><i class="fa ' + aIcon + '" style="color:' + aColor + '"></i> ' +
                '<span style="color:' + aColor + '">' + aLabel + '</span></td></tr>';

            // DHCP row: false = intentionally off (standby), not a failure
            var dIcon, dLabel, dColor;
            if (peer.dhcp === true) {
                dColor = "#00a65a"; dIcon = "fa-check-circle";
                dLabel = "Active" + (typeof peer.leases === "number" ? " (" + peer.leases + " leases)" : "");
            } else if (peer.dhcp === false) {
                dColor = "#f0ad4e"; dIcon = "fa-pause-circle"; dLabel = "Standby";
            } else {
                dColor = "#aaa"; dIcon = "fa-minus-circle"; dLabel = "N/A";
            }
            html += '<tr><td>DHCP</td>' +
                '<td><i class="fa ' + dIcon + '" style="color:' + dColor + '"></i> ' +
                '<span style="color:' + dColor + '">' + dLabel + '</span></td></tr>';

            // Auth row: reflect the real state — no password (open), authenticated,
            // or password required / auth failed.
            if (peer.auth === "none") {
                delete authPending[node.ip];
                html += '<tr><td><i class="fa fa-unlock-alt" style="color:#888"></i> Auth</td>' +
                    '<td><span style="color:#888">No password (open)</span></td></tr>';
            } else if (peer.auth === "ok") {
                delete authPending[node.ip];
                html += '<tr><td><i class="fa fa-lock" style="color:#00a65a"></i> Auth</td>' +
                    '<td><span style="color:#00a65a">Authenticated</span></td></tr>';
            } else if (peer.auth === "denied" && authPending[node.ip]) {
                // Password was just saved, waiting for pihole-ha to pick it up
                html += '<tr><td><i class="fa fa-lock" style="color:#f0ad4e"></i> Auth</td>' +
                    '<td><span style="color:#f0ad4e">' +
                    '<i class="fa fa-spinner fa-spin"></i> Authenticating\u2026</span></td></tr>';
            } else if (peer.auth === "denied") {
                html += '<tr><td><i class="fa fa-lock" style="color:#dd4b39"></i> Auth</td>' +
                    '<td><span style="color:#dd4b39">Password required</span><br>' +
                    '<div style="margin-top:4px;display:flex;gap:4px">' +
                    '<input type="password" class="form-control input-sm ha-auth-input" ' +
                    'id="auth-pw-' + i + '" placeholder="Password" style="width:120px;display:inline-block">' +
                    '<button class="btn btn-xs btn-primary ha-auth-save" data-ip="' + node.ip + '" data-idx="' + i + '">' +
                    '<i class="fa fa-key"></i> Save</button></div></td></tr>';
            }

            // Don't clobber an input the user is actively typing into (e.g. the
            // auth password field): if focus is inside this table, skip its
            // re-render this cycle. Other nodes still update normally.
            var active = document.activeElement;
            if (active && $tbody[0] && $tbody[0].contains(active)) {
                return;
            }

            $tbody.html(html);
        });
    }

    // ---- Render: Sync panel ----

    function renderSync() {
        // Panel is always visible - server-side Lua pre-populates initial state.
        // JS only updates when API data is available.
        if (syncCfg) {
            $("#toggle-enabled").toggleClass("on", syncCfg.enabled);
            $("#toggle-gravity").toggleClass("on", syncCfg.gravity);
            $("#toggle-dhcp").toggleClass("on", syncCfg.dhcp);
            $("#toggle-dns").toggleClass("on", syncCfg.dns);
            $("#toggle-settings").toggleClass("on", syncCfg.settings);

            // Update interval dropdown
            if (syncCfg.interval) {
                var $sel = $("#sync-interval");
                if ($sel.val() !== String(syncCfg.interval)) {
                    $sel.val(String(syncCfg.interval));
                }
            }

            var off = !syncCfg.enabled;
            $("#toggle-gravity, #toggle-dhcp, #toggle-dns, #toggle-settings").toggleClass("disabled", off);
            $(".ha-sync-component").toggleClass("disabled", off);
            $("#sync-now-btn").prop("disabled", off);

            // Update Sync Primary buttons
            if (syncCfg.primary) {
                $.each(PROMOTE_IDS, function (ip, elemId) {
                    var $btn = $("#" + elemId);
                    if (ip === syncCfg.primary) {
                        $btn.removeClass("btn-default").addClass("btn-success");
                    } else {
                        $btn.removeClass("btn-success").addClass("btn-default");
                    }
                });
            }
        }

        // Last sync timestamp from manifest (UTC → viewer's local time)
        if (syncManifest && syncManifest.timestamp) {
            $("#sync-ts").text("Last build: " + fmtTime(syncManifest.timestamp));
        }

        // Cluster entanglement: entangled when sync is on and every peer is
        // reachable; decoherence (link lost) when a peer is unreachable.
        var $ent = $("#sync-entangled");
        var peersOk = !!(statusData && statusData.peers);
        if (peersOk) {
            $.each(NODES, function (i, node) {
                var p = statusData.peers[node.ip];
                if (!(p && p.ping === true)) peersOk = false;
            });
        }
        if (!(syncCfg && syncCfg.enabled)) {
            $ent.hide();
        } else if (peersOk) {
            $ent.attr("class", "label label-success").text("Cluster entangled").show();
        } else {
            $ent.attr("class", "label label-warning").text("Decoherence").show();
        }
    }

    // ---- Toggle handler ----

    window.haToggle = function (key) {
        $.ajax({
            url: API + "?action=toggle&key=" + encodeURIComponent(key),
            timeout: 4000,
            dataType: "json"
        })
        .done(function (data) {
            if (data && !data.error) {
                $.extend(syncCfg, data);
                renderSync();
            } else {
                $("#sync-result")
                    .text("Toggle failed: " + (data && data.error || "unknown"))
                    .show();
            }
        })
        .fail(function (xhr, textStatus, err) {
            $("#sync-result")
                .text("Toggle failed: " + (err || textStatus))
                .show();
            setTimeout(function () {
                $("#sync-result").fadeOut();
            }, 5000);
        });
    };

    // ---- Sync Now handler ----

    window.haSyncNow = function () {
        var $btn = $("#sync-now-btn");
        var $res = $("#sync-result");
        $btn.prop("disabled", true);
        $res.text("Syncing...").show();

        $.ajax({
            url: API + "?action=sync-now",
            timeout: 10000,
            dataType: "json"
        })
        .done(function (data) {
            $res.text(data && data.ok
                ? "Sync triggered (" + data.action + ")"
                : "Sync failed"
            );
        })
        .fail(function (xhr, textStatus, err) {
            $res.text("Error: " + (err || textStatus));
        })
        .always(function () {
            setTimeout(function () {
                $btn.prop("disabled", !syncCfg || !syncCfg.enabled);
                $res.fadeOut();
            }, 5000);
        });
    };

    // ---- Sync Interval handler ----

    window.haSyncInterval = function (minutes) {
        var $res = $("#interval-result");
        $res.text("Saving...").show();
        $.ajax({
            url: API + "?action=set-interval&minutes=" + encodeURIComponent(minutes),
            timeout: 6000,
            dataType: "json"
        })
        .done(function (data) {
            if (data && data.interval) {
                if (syncCfg) syncCfg.interval = data.interval;
                $res.text("Saved: " + data.interval + " min");
            } else {
                $res.text(data && data.error ? data.error : "Failed");
            }
        })
        .fail(function (xhr, textStatus, err) {
            $res.text("Error: " + (err || textStatus));
        })
        .always(function () {
            setTimeout(function () { $res.fadeOut(); }, 4000);
        });
    };

    // ---- Promote handler ----

    window.haPromote = function (ip) {
        // Don't promote to current primary
        if (syncCfg && syncCfg.primary === ip) return;

        var $res = $("#promote-result");
        // Disable all promote buttons during request
        $(".ha-promote-group .btn").prop("disabled", true);
        $res.html('<i class="fa fa-spinner fa-spin"></i> Promoting...').show();

        $.ajax({
            url: API + "?action=promote&ip=" + encodeURIComponent(ip),
            timeout: 10000,
            dataType: "json"
        })
        .done(function (data) {
            if (data && data.ok) {
                $res.html('<span style="color:#00a65a"><i class="fa fa-check"></i> Promoted</span>');
                if (syncCfg) syncCfg.primary = data.primary;
                renderSync();
            } else {
                $res.html('<span style="color:#dd4b39">' + (data && data.error || "Failed") + '</span>');
            }
        })
        .fail(function (xhr, textStatus, err) {
            $res.html('<span style="color:#dd4b39">Error: ' + (err || textStatus) + '</span>');
        })
        .always(function () {
            $(".ha-promote-group .btn").prop("disabled", false);
            setTimeout(function () { $res.fadeOut(function () { $res.text("").show(); }); }, 4000);
            // Re-poll sync config to confirm propagation
            setTimeout(pollSync, 2000);
        });
    };

    // ---- Master polling ----

    function pollMaster() {
        $.ajax({
            url: API + "?action=master-config",
            timeout: 4000,
            dataType: "json"
        })
        .done(function (data) {
            masterCfg = (data && !data.error) ? data : null;
        })
        .fail(function () { masterCfg = null; })
        .always(renderMaster);
    }

    // ---- Render: Master panel ----

    function renderMaster() {
        if (!masterCfg) return;
        var cur = masterCfg.dhcp_master || "auto";

        // Update button states
        $.each(MASTER_IDS, function (val, elemId) {
            var $btn = $("#" + elemId);
            if (val === cur) {
                $btn.removeClass("btn-default").addClass("btn-success");
            } else {
                $btn.removeClass("btn-success").addClass("btn-default");
            }
        });

        // Update status badge
        var $badge = $("#master-status");
        if (cur === "auto") {
            $badge.text("Automatic");
        } else {
            $badge.text("Manual: " + cur);
        }
    }

    // ---- Set Master handler ----

    window.haSetMaster = function (ip) {
        if (masterCfg && masterCfg.dhcp_master === ip) return;

        var $res = $("#master-result");
        $(".ha-promote-group .btn", "#master-panel").prop("disabled", true);
        $res.html('<i class="fa fa-spinner fa-spin"></i> Setting...').show();

        $.ajax({
            url: API + "?action=set-master&ip=" + encodeURIComponent(ip),
            timeout: 10000,
            dataType: "json"
        })
        .done(function (data) {
            if (data && data.ok) {
                $res.html('<span style="color:#00a65a"><i class="fa fa-check"></i> Applied</span>');
                if (masterCfg) masterCfg.dhcp_master = data.dhcp_master;
                renderMaster();
            } else {
                $res.html('<span style="color:#dd4b39">' + (data && data.error || "Failed") + '</span>');
            }
        })
        .fail(function (xhr, textStatus, err) {
            $res.html('<span style="color:#dd4b39">Error: ' + (err || textStatus) + '</span>');
        })
        .always(function () {
            $(".ha-promote-group .btn", "#master-panel").prop("disabled", false);
            setTimeout(function () { $res.fadeOut(function () { $res.text("").show(); }); }, 4000);
            setTimeout(pollMaster, 2000);
        });
    };

    // ---- Priority polling ----

    var prioCfg = null;
    var PRIO_ROLES = ["PRIMARY", "SECONDARY", "TERTIARY"];

    pollPriority();
    setInterval(pollPriority, 5000);

    function pollPriority() {
        $.ajax({
            url: API + "?action=priority-config",
            timeout: 4000,
            dataType: "json"
        })
        .done(function (data) {
            prioCfg = (data && !data.error) ? data : null;
        })
        .fail(function () { prioCfg = null; })
        .always(renderPriority);
    }

    function renderPriority() {
        if (!prioCfg || !prioCfg.nodes) return;
        var nodes = prioCfg.nodes.split(",");

        // Update status badge
        var shorts = nodes.map(function (ip) { return "." + ip.split(".").pop(); });
        $("#priority-status").text(shorts.join(" → "));

        // Rebuild rows
        var html = "";
        nodes.forEach(function (ip, i) {
            var role = PRIO_ROLES[i] || ("NODE" + (i + 1));
            html += '<div class="priority-row" data-ip="' + ip + '" style="display:flex;align-items:center;gap:8px;padding:6px 0;border-bottom:1px solid #eee">';
            html += '<span class="label label-default" style="min-width:28px;text-align:center">P' + (i + 1) + '</span>';
            html += '<strong style="min-width:120px">' + ip + '</strong>';
            html += '<span class="text-muted">' + role + '</span>';
            html += '<span style="margin-left:auto">';
            html += '<button class="btn btn-xs btn-default prio-up" data-idx="' + i + '"' + (i === 0 ? " disabled" : "") + '><i class="fa fa-arrow-up"></i></button>';
            html += '<button class="btn btn-xs btn-default prio-down" data-idx="' + i + '"' + (i === nodes.length - 1 ? " disabled" : "") + '><i class="fa fa-arrow-down"></i></button>';
            html += '</span></div>';
        });
        $("#priority-rows").html(html);
    }

    window.haMovePrio = function (idx, dir) {
        if (!prioCfg || !prioCfg.nodes) return;
        var nodes = prioCfg.nodes.split(",");
        var swapIdx = idx + dir;
        if (swapIdx < 0 || swapIdx >= nodes.length) return;
        var tmp = nodes[idx];
        nodes[idx] = nodes[swapIdx];
        nodes[swapIdx] = tmp;
        haSetPriority(nodes.join(","));
    };

    window.haSetPriority = function (newOrder) {
        var $res = $("#priority-result");
        $(".prio-up, .prio-down").prop("disabled", true);
        $res.html('<i class="fa fa-spinner fa-spin"></i> Updating...').show();

        $.ajax({
            url: API + "?action=set-priority&nodes=" + encodeURIComponent(newOrder),
            timeout: 10000,
            dataType: "json"
        })
        .done(function (data) {
            if (data && data.ok) {
                $res.html('<span style="color:#00a65a"><i class="fa fa-check"></i> Updated</span>');
                prioCfg.nodes = data.nodes;
                renderPriority();
            } else {
                $res.html('<span style="color:#dd4b39">' + (data && data.error || "Failed") + '</span>');
            }
        })
        .fail(function (xhr, textStatus, err) {
            $res.html('<span style="color:#dd4b39">Error: ' + (err || textStatus) + '</span>');
        })
        .always(function () {
            setTimeout(function () { $res.fadeOut(function () { $res.text("").show(); }); }, 4000);
            setTimeout(pollPriority, 2000);
        });
    };

    // ---- VIP polling ----

    function pollVip() {
        $.ajax({
            url: API + "?action=vip-config",
            timeout: 4000,
            dataType: "json"
        })
        .done(function (data) {
            vipCfg = (data && !data.error) ? data : null;
        })
        .fail(function () { vipCfg = null; })
        .always(renderVip);
    }

    // ---- Render: VIP panel ----

    function renderVip() {
        if (!vipCfg) return;
        var enabled = vipCfg.vip_enabled;
        var isMaster = vipCfg.is_master;
        $("#toggle-vip").toggleClass("on", enabled);
        $("#toggle-vip").toggleClass("disabled", !isMaster);
        if (enabled) {
            $("#vip-details").show();
        } else {
            $("#vip-details").hide();
        }
        var $badge = $("#vip-status");
        var text = enabled ? "Enabled" : "Disabled";
        if (!isMaster) text += " (only DHCP master can toggle)";
        $badge.text(text);
    }

    // ---- VIP toggle handler ----

    window.haVipToggle = function () {
        if (vipCfg && !vipCfg.is_master) {
            renderVip();
            return;
        }
        $.ajax({
            url: API + "?action=vip-toggle",
            timeout: 5000,
            dataType: "json"
        })
        .done(function (data) {
            if (data && !data.error) {
                if (vipCfg) $.extend(vipCfg, data);
                renderVip();
            } else {
                renderVip();  // revert toggle visual
            }
        })
        .fail(function () {
            renderVip();
        });
    };

    // ---- Notify polling ----

    function pollNotify() {
        $.ajax({
            url: API + "?action=notify-config",
            timeout: 4000,
            dataType: "json"
        })
        .done(function (data) {
            notifyCfg = (data && !data.error) ? data : null;
        })
        .fail(function () { notifyCfg = null; })
        .always(renderNotify);
    }

    function loadDhcpHostPicker() {
        $.ajax({
            url: API + "?action=notify-dhcp-hosts",
            timeout: 5000,
            dataType: "json"
        })
        .done(function (hosts) {
            if (!hosts || !hosts.length) {
                $("#dhcp-host-picker").html('<small class="text-muted">No static hosts configured</small>');
                return;
            }
            var html = "";
            hosts.forEach(function (h) {
                var macs = h.macs || h.mac;
                var extra = macs.split(",").length - 1;
                html += '<div class="dhcp-pick-row" style="padding:2px 0;cursor:pointer" data-mac="' + escapeHtml(macs) + '">' +
                    '<code style="font-size:11px">' + escapeHtml(h.mac) + '</code>' +
                    (extra > 0 ? '<code class="text-muted" style="font-size:11px;margin-left:4px">+' + extra + '</code>' : '') +
                    '<span class="text-muted" style="margin-left:8px;font-size:12px">' +
                    (h.name ? escapeHtml(h.name) + ' ' : '') + '(' + escapeHtml(h.ip) + ')</span>' +
                    '</div>';
            });
            $("#dhcp-host-picker").html(html);
        })
        .fail(function () {
            $("#dhcp-host-picker").html('<small class="text-muted">Failed to load hosts</small>');
        });
    }

    $(document).on("click", "#toggle-dhcp-notify", function () {
        var isOn = $(this).hasClass("on");
        $(this).toggleClass("on", !isOn);
        if (!isOn) {
            $("#dhcp-notify-fields").show();
            loadDhcpHostPicker();
        } else {
            $("#dhcp-notify-fields").hide();
        }
    });

    $(document).on("click", ".dhcp-pick-row", function () {
        var macs = String($(this).data("mac")).split(",");
        var $ta = $("#dhcp-ignored-macs");
        var added = false;
        macs.forEach(function (mac) {
            mac = mac.trim();
            if (!mac) return;
            var current = $ta.val().trim();
            var lines = current ? current.split("\n").map(function (l) { return l.trim().toLowerCase(); }) : [];
            if (lines.indexOf(mac.toLowerCase()) === -1) {
                $ta.val(current ? current + "\n" + mac : mac);
                added = true;
            }
        });
        if (added) $ta.data("dirty", true);
    });

    // Render: Notify panel
    function renderNotify() {
        if (!notifyCfg) return;
        $("#toggle-notify").toggleClass("on", notifyCfg.enabled);
        $("#notify-fields").toggle(!!notifyCfg.enabled);
        var dhcpOn = notifyCfg.dhcp_enabled !== false;
        $("#toggle-dhcp-notify").toggleClass("on", dhcpOn);
        if (dhcpOn) {
            $("#dhcp-notify-fields").show();
            // Populate textarea if not already touched
            if (notifyCfg.dhcp_ignored_macs && !$("#dhcp-ignored-macs").data("dirty")) {
                $("#dhcp-ignored-macs").val(notifyCfg.dhcp_ignored_macs.replace(/,/g, "\n"));
            }
            if (notifyCfg.dhcp_ignored_hosts && !$("#dhcp-ignored-hosts").data("dirty")) {
                $("#dhcp-ignored-hosts").val(notifyCfg.dhcp_ignored_hosts.replace(/,/g, "\n"));
            }
            loadDhcpHostPicker();
        } else {
            $("#dhcp-notify-fields").hide();
        }
        var $badge = $("#notify-status");
        if (notifyCfg.enabled && notifyCfg.has_user && notifyCfg.has_token) {
            $badge.html('<i class="fa fa-check"></i> Active');
        } else if (notifyCfg.enabled) {
            $badge.html('<i class="fa fa-exclamation-triangle"></i> Incomplete');
        } else {
            $badge.text("Disabled");
        }
    }

    // Mark textarea dirty when user edits it manually
    $(document).on("input", "#dhcp-ignored-macs", function () {
        $(this).data("dirty", true);
    });
    $(document).on("input", "#dhcp-ignored-hosts", function () {
        $(this).data("dirty", true);
    });

    // ---- Notify toggle handler ----

    window.haNotifyToggle = function () {
        $.ajax({
            url: API + "?action=notify-toggle",
            timeout: 4000,
            dataType: "json"
        })
        .done(function (data) {
            if (data && !data.error) {
                if (notifyCfg) $.extend(notifyCfg, data);
                else notifyCfg = data;
                renderNotify();
            }
        });
    };

    // ---- Notify save handler ----

    window.haNotifySave = function () {
        var user = $("#notify-user").val();
        var token = $("#notify-token").val();
        var title = $("#notify-title").val() || "pihole-ha";
        var enabled = $("#toggle-notify").hasClass("on");
        var dhcpEnabled = $("#toggle-dhcp-notify").hasClass("on");
        // Convert textarea (one-per-line) to comma-separated for storage
        var dhcpMacs = $("#dhcp-ignored-macs").val()
            .split("\n").map(function (l) { return l.trim(); })
            .filter(function (l) { return l.length > 0; })
            .join(",");
        var dhcpHosts = $("#dhcp-ignored-hosts").val()
            .split("\n").map(function (l) { return l.trim(); })
            .filter(function (l) { return l.length > 0; })
            .join(",");
        if (user === "********") user = "";
        if (token === "********") token = "";
        var $res = $("#notify-result");
        var hasCreds = notifyCfg && notifyCfg.has_user && notifyCfg.has_token;
        if (!user && !token && !hasCreds) {
            $res.html('<span style="color:#dd4b39">Enter user key and token</span>');
            setTimeout(function () { $res.fadeOut(function () { $res.text("").show(); }); }, 3000);
            return;
        }
        $.ajax({
            url: API + "?action=notify-save" +
                "&enabled=" + enabled +
                "&user=" + encodeURIComponent(user) +
                "&token=" + encodeURIComponent(token) +
                "&title=" + encodeURIComponent(title) +
                "&dhcp_enabled=" + dhcpEnabled +
                "&dhcp_macs=" + encodeURIComponent(dhcpMacs) +
                "&dhcp_hosts=" + encodeURIComponent(dhcpHosts),
            timeout: 4000,
            dataType: "json"
        })
        .done(function (data) {
            if (data && data.ok) {
                $res.html('<span style="color:#00a65a"><i class="fa fa-check"></i> Saved</span>');
                $("#dhcp-ignored-macs").data("dirty", false);
                $("#dhcp-ignored-hosts").data("dirty", false);
                pollNotify();
            } else {
                $res.html('<span style="color:#dd4b39">Save failed</span>');
            }
        })
        .fail(function () {
            $res.html('<span style="color:#dd4b39">Save failed</span>');
        })
        .always(function () {
            setTimeout(function () { $res.fadeOut(function () { $res.text("").show(); }); }, 3000);
        });
    };

    // ---- Notify test handler ----

    window.haNotifyTest = function () {
        var $btn = $("#notify-test-btn");
        var $res = $("#notify-result");
        $btn.prop("disabled", true);
        $res.html('<i class="fa fa-spinner fa-spin"></i> Sending...');
        $.ajax({
            url: API + "?action=notify-test",
            timeout: 10000,
            dataType: "json"
        })
        .done(function (data) {
            if (data && data.ok) {
                $res.html('<span style="color:#00a65a"><i class="fa fa-check"></i> Sent!</span>');
            } else {
                $res.html('<span style="color:#dd4b39">' + (data && data.error || "Failed") + '</span>');
            }
        })
        .fail(function () {
            $res.html('<span style="color:#dd4b39">Failed to send</span>');
        })
        .always(function () {
            $btn.prop("disabled", false);
            setTimeout(function () { $res.fadeOut(function () { $res.text("").show(); }); }, 4000);
        });
    };

    // ---- HA polling ----

    function pollHa() {
        $.ajax({
            url: API + "?action=ha-config",
            timeout: 4000,
            dataType: "json"
        })
        .done(function (data) {
            haCfg = (data && !data.error) ? data : null;
        })
        .fail(function () { haCfg = null; })
        .always(renderHa);
    }

    // ---- Version / update indicator ----
    function pollVersion() {
        $.ajax({
            url: API + "?action=version",
            timeout: 6000,
            dataType: "json"
        })
        .done(function (d) {
            if (!d) return;
            // The version number is rendered server-side (always present); only
            // overwrite it with a valid value from the API, never with "unknown".
            if (d.local && d.local !== "unknown") $("#ha-version-local").text("v" + d.local);
            if (d.update_available && d.latest) {
                // Show the update command on its own line under the version so it
                // isn't missed - people forget the exact command.
                $("#ha-version-update").html(
                    ' &middot; <span style="color:#f0ad4e"><i class="fa fa-arrow-circle-up"></i> ' +
                    'update available (v' + escapeHtml(d.latest) + ')</span>' +
                    '<br><span style="color:#f0ad4e;font-size:12px">To update, run: ' +
                    '<code style="background:rgba(240,173,78,0.15);padding:1px 6px;border-radius:3px">' +
                    'sudo pihole-ha update</code></span>'
                );
            } else if (d.latest) {
                $("#ha-version-update").html(' &middot; <span style="color:#00a65a">up to date</span>');
            }
            // check disabled/unreachable (no latest): leave suffix empty - version still shows
        });
    }

    // ---- Render: HA panel ----

    function renderHa() {
        if (!haCfg) return;
        var enabled = haCfg.ha_enabled;
        $("#toggle-ha").toggleClass("on", enabled);
        var $badge = $("#ha-status");
        if (enabled) {
            $badge.text("Active");
            $("#ha-disabled-banner").hide();
        } else {
            $badge.text("DISABLED");
            $("#ha-disabled-banner").show();
        }
    }

    // ---- HA toggle handler ----

    window.haHaToggle = function () {
        $.ajax({
            url: API + "?action=ha-toggle",
            timeout: 5000,
            dataType: "json"
        })
        .done(function (data) {
            if (data && !data.error) {
                if (haCfg) $.extend(haCfg, data);
                renderHa();
            }
        });
    };

    // ---- Auth password handler ----

    window.haSetAuth = function (ip, idx) {
        var pw = $("#auth-pw-" + idx).val();
        if (!pw) return;
        // Set flag and update DOM immediately (before AJAX) so any in-flight
        // pollStatus that completes won't flash the password field back
        authPending[ip] = true;
        var $row = $("#auth-pw-" + idx).closest("tr");
        $row.find("td:last").html(
            '<span style="color:#f0ad4e">' +
            '<i class="fa fa-spinner fa-spin"></i> Authenticating\u2026</span>'
        );
        $.ajax({
            url: API + "?action=set-auth&ip=" + encodeURIComponent(ip) + "&password=" + encodeURIComponent(pw),
            timeout: 4000,
            dataType: "json"
        })
        .done(function (data) {
            if (!data || !data.ok) {
                delete authPending[ip];
                pollStatus();  // re-render with actual state
            }
        })
        .fail(function () {
            delete authPending[ip];
            pollStatus();  // re-render with actual state
        });
    };
});
