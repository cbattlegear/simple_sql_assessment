(() => {
  "use strict";
  const data = JSON.parse(document.getElementById("ssa-data").textContent);
  const own = (object, key) => object != null && Object.prototype.hasOwnProperty.call(object, key);
  const value = (object, key, fallback = null) => own(object, key) ? object[key] : fallback;
  const array = input => Array.isArray(input) ? input.filter(item => item != null) : [];
  const text = input => input == null || input === "" ? "Not available" :
    typeof input === "object" ? JSON.stringify(input, null, 2) : String(input);
  const targetNames = { SqlDatabase: "Azure SQL Database", ManagedInstance: "Azure SQL Managed Instance", SqlVm: "SQL Server on Azure VM" };
  const targets = Object.keys(targetNames);
  const findings = array(data.Findings);
  const evaluations = array(data.RuleEvaluations);
  const recommendations = array(data.Recommendations);
  const prices = array(data.Prices);
  const byId = id => document.getElementById(id);
  function element(tag, content, className) {
    const node = document.createElement(tag);
    if (content != null) node.textContent = text(content);
    if (className) node.className = className;
    return node;
  }
  function empty(parent, message) { parent.append(element("p", message, "empty")); }
  function badge(status) {
    const kind = /^(Issue|Error|Blocked|Unavailable|NoFit)$/.test(status) ? "danger" :
      /^(Warning|NeedsReview|Partial|Pending|Running|Interrupted|FailedResumable)$/.test(status) ? "warning" :
        /^(Pass|Complete|Completed|Compatible)$/.test(status) ? "success" : "";
    return element("span", status, "badge " + kind);
  }
  function facts(parent, entries) {
    const dl = element("dl", null, "facts");
    entries.forEach(([label, content]) => { dl.append(element("dt", label), element("dd", content)); });
    parent.append(dl);
  }
  function detail(parent, title, content) {
    if (content == null || (Array.isArray(content) && !content.length)) return;
    const container = element("details");
    container.append(element("summary", title), element("pre", content));
    parent.append(container);
  }
  function documentation(url) {
    const span = element("span");
    if (typeof url !== "string" || !url) { span.textContent = "Not supplied"; return span; }
    try {
      const parsed = new URL(url);
      if (parsed.protocol !== "https:" || parsed.username || parsed.password ||
        !["learn.microsoft.com", "docs.microsoft.com", "support.microsoft.com"].includes(parsed.hostname.toLowerCase()) ||
        (parsed.port && parsed.port !== "443")) throw new Error("Not an approved documentation URL");
      const link = element("a", "Microsoft documentation");
      link.href = parsed.href;
      link.target = "_blank";
      link.rel = "noopener noreferrer";
      return link;
    } catch (_) {
      span.textContent = "Documentation URL not permitted";
      return span;
    }
  }
  function money(amount, currency) {
    if (typeof amount !== "number" || !Number.isFinite(amount)) return "Not available";
    return amount.toLocaleString(undefined, { maximumFractionDigits: 2, minimumFractionDigits: 2 }) + " " + text(currency);
  }
  function config(recommendation) {
    return ["ServiceTier", "Hardware", "VCores", "VmSize", "SqlEdition", "SqlMajorVersion"]
      .filter(key => value(recommendation, key) != null && value(recommendation, key) !== "")
      .map(key => key + ": " + text(recommendation[key])).join(" · ") || "Configuration not available";
  }
  function table(parent, rows, columns, caption, sortable = false) {
    if (!rows.length) { empty(parent, "No rows available for this view."); return; }
    const wrap = element("div", null, "table-wrap");
    wrap.tabIndex = 0;
    wrap.setAttribute("role", "region");
    wrap.setAttribute("aria-label", caption + " (scroll horizontally if needed)");
    const grid = element("table");
    grid.append(element("caption", caption));
    const head = element("thead");
    const heading = element("tr");
    const body = element("tbody");
    let sortKey = null, ascending = true;
    function draw() {
      body.replaceChildren();
      const ordered = rows.slice();
      if (sortKey) {
        ordered.sort((a, b) => {
          const left = value(a, sortKey), right = value(b, sortKey);
          if (left == null && right == null) return 0;
          if (left == null) return 1;
          if (right == null) return -1;
          const result = typeof left === "number" && typeof right === "number" ? left - right :
            text(left).localeCompare(text(right), undefined, { numeric: true, sensitivity: "base" });
          return ascending ? result : -result;
        });
      }
      ordered.forEach(row => {
        const tr = element("tr");
        columns.forEach(column => {
          const td = element("td");
          if (column.render) td.append(column.render(row));
          else td.textContent = text(value(row, column.key));
          tr.append(td);
        });
        body.append(tr);
      });
      Array.from(heading.children).forEach((th, index) => {
        const active = columns[index].key === sortKey;
        th.setAttribute("aria-sort", active ? (ascending ? "ascending" : "descending") : "none");
      });
    }
    columns.forEach(column => {
      const th = element("th");
      th.scope = "col";
      if (sortable && column.key) {
        const button = element("button", column.label);
        button.type = "button";
        button.setAttribute("aria-label", "Sort by " + column.label);
        button.addEventListener("click", () => {
          ascending = sortKey === column.key ? !ascending : true;
          sortKey = column.key;
          draw();
        });
        th.append(button);
      } else th.textContent = column.label;
      heading.append(th);
    });
    head.append(heading);
    grid.append(head, body);
    wrap.append(grid);
    parent.append(wrap);
    draw();
  }
  const columns = keys => keys.map(key => ({ key, label: key.replace(/([a-z])([A-Z])/g, "$1 $2") }));
  const docColumn = { key: "SourceUrl", label: "Documentation", render: row => documentation(row.SourceUrl) };
  function filteredTable(prefix, rows, columnDefinitions, statusFor) {
    const container = byId(prefix + "-filters");
    const controls = {};
    const definitions = [["Target", "Target"], ["Database", "Database"], ["Category", "Severity"], ["RuleId", "Rule"], ["Status", "Evaluation status"]];
    definitions.forEach(([key, labelText]) => {
      const label = element("label", labelText);
      const select = element("select");
      select.id = prefix + "-filter-" + key.toLowerCase();
      label.htmlFor = select.id;
      const all = element("option", "All " + labelText.toLowerCase());
      all.value = "";
      select.append(all);
      const options = new Set(rows.map(row => key === "Status" ? statusFor(row) : value(row, key)).filter(item => item != null && item !== ""));
      if (key === "Target") targets.forEach(target => options.add(target));
      if (key === "Status") ["Pass", "Finding", "NotApplicable", "NeedsReview", "Error"].forEach(status => options.add(status));
      Array.from(options).sort().forEach(option => {
        const item = element("option", key === "Target" ? (targetNames[option] || option) : option);
        item.value = String(option);
        select.append(item);
      });
      controls[key] = select;
      label.append(select);
      container.append(label);
    });
    const label = element("label", "Search text");
    const search = element("input");
    search.id = prefix + "-filter-text";
    search.type = "search";
    label.htmlFor = search.id;
    label.append(search);
    const reset = element("button", "Reset filters");
    reset.type = "button";
    container.append(label, reset);
    const draw = () => {
      const query = search.value.trim().toLocaleLowerCase();
      const visible = rows.filter(row => Object.keys(controls).every(key => {
        const selected = controls[key].value;
        return !selected || String(key === "Status" ? statusFor(row) : value(row, key)) === selected;
      }) && (!query || JSON.stringify(row).toLocaleLowerCase().includes(query)));
      byId(prefix + "-count").textContent = visible.length + " of " + rows.length + " rows shown";
      const destination = byId(prefix + "-table");
      destination.replaceChildren();
      table(destination, visible, columnDefinitions, prefix === "findings" ? "Findings and remediation" : "Supplied rule evaluations", true);
    };
    Object.values(controls).forEach(control => control.addEventListener("change", draw));
    search.addEventListener("input", draw);
    reset.addEventListener("click", () => { Object.values(controls).forEach(control => { control.value = ""; }); search.value = ""; draw(); });
    draw();
    return { reset, draw };
  }

  byId("snapshot-meta").textContent = "Instance: " + text(value(data.Source, "Instance")) +
    " · Generated: " + text(data.GeneratedAt) + " · Assessment: " + text(data.AssessmentId);
  targets.forEach(target => {
    const summary = array(data.Targets).find(row => row.Target === target) || {};
    const card = element("article", null, "target-card");
    card.append(element("h3", targetNames[target]), badge(value(summary, "Compatibility", "Not assessed")));
    facts(card, [
      ["Blockers / warnings / review", [summary.BlockerCount, summary.WarningCount, summary.ReviewCount].map(text).join(" / ")],
      ["Sizing", value(summary, "SizingStatus", "Unavailable")],
      ["PAYG / month", money(summary.MonthlyPayg, value(data.Configuration, "Currency"))],
      ["AHB / month", money(summary.MonthlyAhb, value(data.Configuration, "Currency"))]
    ]);
    const matches = recommendations.filter(row => row.Target === target);
    if (!matches.length) card.append(element("p", "No supported configuration supplied.", "muted"));
    matches.forEach(row => {
      card.append(element("p", text(row.Database || "Instance") + " · " + text(row.Status) + " · " + config(row)));
    });
    const targetIds = new Set(matches.map(row => row.RecommendationId));
    const quotes = prices.filter(quote => targetIds.has(quote.RecommendationId));
    card.append(element("p", quotes.length ? "Price evidence: " + quotes.map(quote => text(quote.Scenario) + " " + text(quote.Status)).join("; ") :
      "Price evidence unavailable.", "muted"));
    const link = element("a", "Review supporting findings");
    link.href = "#findings";
    link.addEventListener("click", () => {
      byId("findings-filter-target").value = target;
      byId("findings-filter-target").dispatchEvent(new Event("change"));
    });
    card.append(link);
    byId("target-cards").append(card);
  });
  facts(byId("source-summary"), ["Instance", "ComputerName", "VersionMajor", "Edition"].map(key => [key, value(data.Source, key)]));
  const inventory = data.Inventory;
  const databases = array(data.Databases).length ? array(data.Databases) :
    Array.isArray(inventory) ? array(inventory) : array(value(inventory, "Databases", value(data.Source, "Databases", [])));
  if (databases.length) {
    const inventoryFields = ["Id", "Database", "Name", "State", "AssessmentState", "CompatibilityLevel", "DataMB", "LogMB", "SizeGB", "DataGB", "LogGB"];
    table(byId("inventory-content"), databases, columns(inventoryFields.filter(key => databases.some(row => own(row, key)))), "Database inventory (MB and GB are labeled as supplied)");
    detail(byId("inventory-content"), "Inventory evidence and access/exclusion details", databases);
  } else empty(byId("inventory-content"), "Database inventory was not included in this assessment. No inventory access or completeness is assumed.");
  detail(byId("inventory-content"), "Dependencies", value(data, "Dependencies", value(inventory, "Dependencies")));
  detail(byId("inventory-content"), "Additional inventory evidence", !Array.isArray(inventory) ? inventory : null);

  const clientEvidence = value(data, "ClientDependencies", {}) || {};
  const clients = array(clientEvidence.Clients);
  facts(byId("client-summary"), [
    ["Snapshot status", value(clientEvidence, "Status", "NotCollected")],
    ["Successful snapshots", value(clientEvidence, "SnapshotsObserved", 0)],
    ["Unavailable / legacy snapshots", text(value(clientEvidence, "SnapshotsUnavailable", 0)) + " / " + text(value(clientEvidence, "SnapshotsNotCollected", 0))],
    ["First / last successful snapshot (UTC)", text(clientEvidence.FirstSnapshotAt) + " / " + text(clientEvidence.LastSnapshotAt)],
    ["Capture cadence (seconds)", clientEvidence.SampleIntervalSeconds]
  ]);
  if (!value(clientEvidence, "SnapshotsObserved", 0)) {
    empty(byId("client-summary"), "No usable client snapshots. This does not establish that no external machines connect to SQL Server.");
  }
  const clientFilter = element("label", "Client location");
  const clientLocation = element("select");
  clientLocation.id = "client-filter-location";
  clientFilter.htmlFor = clientLocation.id;
  [["", "All locations"], ["Remote", "Remote"], ["Local", "Local"], ["Unknown", "Unknown"]].forEach(([key, title]) => {
    const option = element("option", title); option.value = key; clientLocation.append(option);
  });
  clientFilter.append(clientLocation);
  const clientSearchLabel = element("label", "Search clients");
  const clientSearch = element("input");
  clientSearch.id = "client-filter-text"; clientSearch.type = "search";
  clientSearchLabel.htmlFor = clientSearch.id; clientSearchLabel.append(clientSearch);
  byId("client-filters").append(clientFilter, clientSearchLabel);
  function drawClients() {
    const query = clientSearch.value.trim().toLocaleLowerCase();
    const rows = clients.filter(row => (!clientLocation.value || row.Location === clientLocation.value) &&
      (!query || JSON.stringify(row).toLocaleLowerCase().includes(query)));
    byId("client-count").textContent = rows.length + " of " + clients.length + " observed client groups shown";
    byId("client-table").replaceChildren();
    table(byId("client-table"), rows, [
      ...columns(["Location", "ClientAddress", "HostName", "ProgramName", "LoginName"]),
      { key: "Databases", label: "Observed database contexts", render: row => element("span", array(row.Databases).join(", ") || "Not available") },
      ...columns(["SamplesSeen", "PeakSessions", "FirstObservedAt", "LastObservedAt"])
    ], "Observed inbound clients (sightings, not login counts; UTC times)", true);
  }
  clientLocation.addEventListener("change", drawClients);
  clientSearch.addEventListener("input", drawClients);
  drawClients();
  detail(byId("client-details"), "Driver, transport, authentication, and encryption evidence", clients);
  detail(byId("client-details"), "Client collection diagnostics", clientEvidence.Diagnostics);
  detail(byId("client-details"), "Observation method and limitations", clientEvidence.Notes);

  const evaluationIndex = new Map();
  const evaluationKey = row => JSON.stringify([row.Target, row.RuleId, row.Database || ""]);
  evaluations.forEach(row => {
    const key = evaluationKey(row);
    if (!evaluationIndex.has(key)) evaluationIndex.set(key, []);
    evaluationIndex.get(key).push(row.Status);
  });
  const findingStatus = row => {
    const states = evaluationIndex.get(evaluationKey(row)) || [];
    return ["Error", "NeedsReview", "Finding", "Pass", "NotApplicable"].find(state => states.includes(state)) || "Finding";
  };
  const findingControls = filteredTable("findings", findings,
    [...columns(["Target", "RuleId", "Category", "PublishedCategory", "Scope", "Database", "Object", "Line", "Message", "Remediation"]),
      { label: "Evaluation status", render: row => element("span", findingStatus(row)) }, docColumn], findingStatus);
  const coverage = byId("coverage-summary");
  targets.forEach(target => {
    const rows = evaluations.filter(row => row.Target === target);
    const uniqueRules = new Set(rows.map(row => row.RuleId).filter(Boolean)).size;
    const expected = target === "SqlDatabase" ? 30 : target === "ManagedInstance" ? 34 : null;
    const description = targetNames[target] + ": " + uniqueRules + (expected ? " / " + expected : "") + " distinct rule mappings supplied; " +
      ["Pass", "Finding", "NotApplicable", "NeedsReview", "Error"].map(status => status + " " + rows.filter(row => row.Status === status).length).join(" · ");
    coverage.append(element("p", description));
    if (!rows.length || (expected && uniqueRules < expected)) coverage.append(element("p", "Incomplete or absent rule coverage for " + targetNames[target] + ". Do not infer unlisted outcomes.", "notice"));
  });
  const coverageControls = filteredTable("coverage", evaluations, [...columns(["Target", "RuleId", "Database", "Status", "Category", "Message"]), docColumn], row => row.Status);

  const performance = data.Performance || {};
  const state = value(performance, "State", "Unavailable");
  byId("capture-summary").append(badge(state));
  if (state !== "Completed") byId("capture-summary").append(element("p", "Provisional or unavailable evidence: performance-dependent sizing and prices must be reviewed.", "notice"));
  facts(byId("capture-summary"), [
    ["Requested observation (seconds)", performance.RequestedSeconds],
    ["Usable observation (seconds)", performance.UsableSeconds],
    ["Actual collection span (seconds)", performance.WallSeconds],
    ["Coverage (usable / requested)", typeof performance.UsableSeconds === "number" && performance.RequestedSeconds > 0 ?
      (100 * performance.UsableSeconds / performance.RequestedSeconds).toFixed(1) + "% (observation time only)" : "Not available"]
  ]);
  const gaps = array(performance.Gaps);
  if (gaps.length) {
    table(byId("capture-gaps"), gaps.map(gap => typeof gap === "object" ? gap : { Reason: gap }),
      columns(["Start", "End", "StartTime", "EndTime", "DurationSeconds", "Reason"]), "Capture gaps and interruptions");
    detail(byId("capture-gaps"), "Complete gap evidence", gaps);
  } else empty(byId("capture-gaps"), "No explicit gaps supplied; this does not establish uninterrupted observation.");
  detail(byId("capture-gaps"), "Missing metrics", performance.MissingMetrics);
  detail(byId("capture-summary"), "Report series downsampling and original point counts", performance.ReportSeries);
  table(byId("metric-summary"), array(performance.Summary), columns(["Metric", "Database", "P95", "Peak", "Unit"]), "Percentiles and peaks from supplied evidence");
  detail(byId("metric-summary"), "Capture evidence and assumptions", Object.fromEntries(Object.entries(performance).filter(([key]) => !["Series", "Summary", "Gaps"].includes(key))));

  // Downsample only for drawing. Keep global extrema and split gaps before selecting points.
  function downsample(points, limit) {
    if (points.length <= limit) return points;
    const selected = [points[0]];
    const buckets = Math.max(1, Math.floor((limit - 2) / 2));
    const width = (points.length - 2) / buckets;
    for (let bucket = 0; bucket < buckets; bucket++) {
      const slice = points.slice(1 + Math.floor(bucket * width), 1 + Math.floor((bucket + 1) * width));
      if (!slice.length) continue;
      let low = slice[0], high = slice[0];
      slice.forEach(point => { if (point.y < low.y) low = point; if (point.y > high.y) high = point; });
      [low, high].sort((a, b) => a.x - b.x).forEach(point => { if (selected[selected.length - 1] !== point) selected.push(point); });
    }
    selected.push(points[points.length - 1]);
    return selected;
  }
  function chart(metric, title, unit) {
    const figure = element("figure");
    const caption = element("figcaption", title + " (" + unit + ")");
    figure.append(caption);
    const series = array(performance.Series).map(row => ({ x: Date.parse(row.Timestamp), y: value(row, metric) }))
      .filter(point => Number.isFinite(point.x)).sort((a, b) => a.x - b.x);
    const valid = series.filter(point => typeof point.y === "number" && Number.isFinite(point.y));
    if (!valid.length) { empty(figure, "Metric unavailable. Missing samples are not zero."); byId("performance-charts").append(figure); return; }
    const intervals = series.slice(1).map((point, index) => point.x - series[index].x).filter(delta => delta > 0).sort((a, b) => a - b);
    const cadence = intervals.length ? intervals[Math.floor((intervals.length - 1) / 2)] : Infinity;
    const sampleSeconds = value(performance, "SampleIntervalSeconds");
    const gapThreshold = performance.ReportSeries ? Infinity :
      typeof sampleSeconds === "number" && sampleSeconds > 0 ? sampleSeconds * 1500 : cadence * 1.5;
    const explicitGaps = [...gaps, ...array(value(performance.ReportSeries, "Discontinuities"))]
      .map(gap => [Date.parse(gap.Start || gap.StartTime || gap.StartedAt), Date.parse(gap.End || gap.EndTime || gap.EndedAt)])
      .filter(([start, end]) => Number.isFinite(start) && Number.isFinite(end));
    let segments = [], current = [];
    series.forEach(point => {
      const previous = current[current.length - 1];
      if (typeof point.y !== "number" || !Number.isFinite(point.y)) {
        if (current.length) segments.push(current);
        current = [];
        return;
      }
      if (previous && (point.x - previous.x > gapThreshold ||
        explicitGaps.some(([start, end]) => previous.x < end && point.x > start))) {
        segments.push(current);
        current = [];
      }
      current.push(point);
    });
    if (current.length) segments.push(current);
    let minimum = valid[0].y, maximum = valid[0].y;
    valid.forEach(point => { minimum = Math.min(minimum, point.y); maximum = Math.max(maximum, point.y); });
    const first = valid[0].x, last = valid[valid.length - 1].x;
    const x = timestamp => 56 + (timestamp - first) / (last - first || 1) * 520;
    const y = amount => 170 - (amount - minimum) / (maximum - minimum || 1) * 140;
    const svg = document.createElementNS("http://www.w3.org/2000/svg", "svg");
    svg.setAttribute("viewBox", "0 0 620 216");
    svg.setAttribute("role", "img");
    svg.setAttribute("aria-label", title + ": minimum " + minimum + ", peak " + maximum + " " + unit + "; " + valid.length + " usable points; gaps are disconnected.");
    function shape(tag, attributes, content) {
      const node = document.createElementNS("http://www.w3.org/2000/svg", tag);
      Object.entries(attributes).forEach(([key, val]) => node.setAttribute(key, String(val)));
      if (content != null) node.textContent = content;
      svg.append(node);
    }
    shape("line", { x1: 56, y1: 170, x2: 576, y2: 170, class: "chart-axis" });
    shape("line", { x1: 56, y1: 30, x2: 56, y2: 170, class: "chart-axis" });
    shape("text", { x: 4, y: 32, class: "chart-label" }, maximum.toLocaleString(undefined, { maximumFractionDigits: 2 }));
    shape("text", { x: 4, y: 174, class: "chart-label" }, minimum.toLocaleString(undefined, { maximumFractionDigits: 2 }));
    shape("text", { x: 56, y: 198, class: "chart-label" }, new Date(first).toISOString());
    shape("text", { x: 576, y: 212, class: "chart-label", "text-anchor": "end" }, new Date(last).toISOString());
    segments.forEach(segment => {
      const points = downsample(segment, Math.max(4, Math.floor(400 * segment.length / valid.length)));
      if (points.length === 1) shape("circle", { cx: x(points[0].x), cy: y(points[0].y), r: 3, class: "chart-point" });
      else shape("polyline", { points: points.map(point => x(point.x) + "," + y(point.y)).join(" "), class: "chart-line" });
    });
    figure.append(svg, element("p", valid.length + " usable points · " + segments.length + " connected segment(s) · peak " + maximum + " " + unit, "muted"));
    byId("performance-charts").append(figure);
  }
  [["CpuPercent", "CPU", "%"], ["MemoryGB", "SQL memory", "GB"], ["Iops", "I/O operations", "IOPS"],
    ["ThroughputMBps", "I/O throughput", "MB/s"], ["LogMBps", "Log generation", "MB/s"]].forEach(metric => chart(...metric));

  if (!recommendations.length) empty(byId("recommendation-content"), "No sizing recommendation supplied. Missing evidence is not a zero-sized workload.");
  recommendations.forEach(row => {
    const card = element("article", null, "detail-card");
    card.append(element("h3", (targetNames[row.Target] || text(row.Target)) + " / " + text(row.Database || "Instance") + " / " + text(row.RecommendationId)), badge(row.Status));
    facts(card, ["RecommendationId", "CatalogId", "DiskType", "ServiceTier", "Hardware", "VCores", "MemoryGB", "AdditionalMemoryGB", "DataGB", "LogGB", "TempdbGB", "ReservedStorageGB", "ProvisionedIops", "IncludedIops", "AdditionalIops", "TempdbPlacement", "VmSize", "BaseVmSize", "BaseVCores", "VmGeneration", "VmPreview", "LocalTempDisks", "LocalTempDiskGB", "LocalTempGB", "LocalTempDiskType", "RemoteDiskController", "SqlEdition", "SqlMajorVersion", "Confidence", "Reason"].map(key => [key, value(row, key)]));
    detail(card, "Provisioned disks (per-disk GiB, IOPS and decimal MB/s; Count is quantity)", row.DiskLayout);
    detail(card, "Observed SQL latency and volume queue evidence (not a target SLA)", row.StorageAssessment);
    detail(card, "Constraints, resource limits, and no-fit evidence", row.Constraints);
    detail(card, "Sizing evidence, headroom, and alternatives", Object.fromEntries(Object.entries(row).filter(([key]) =>
      !["RecommendationId", "Target", "Database", "Status", "Constraints", "PriceComponents"].includes(key))));
    detail(card, "Required price components", row.PriceComponents);
    byId("recommendation-content").append(card);
  });
  detail(byId("recommendation-content"), "Assessment sizing evidence", data.SizingEvidence);
  facts(byId("price-assumptions"), [
    ["Region", value(data.Configuration, "Region")], ["Currency", value(data.Configuration, "Currency")],
    ["Monthly hours", value(data.Configuration, "HoursPerMonth")],
    ["AHB eligibility assertion", value(data.Configuration, "AhbEligible", value(data.Configuration, "AzureHybridBenefit", "Not supplied; review eligibility"))]
  ]);
  detail(byId("price-assumptions"), "All configured pricing and model assumptions", data.Configuration);
  if (!prices.length) empty(byId("pricing-content"), "No price quotes supplied. This does not mean the workload costs zero.");
  const diskComparison = recommendations.filter(row => row.Target === "SqlVm" && row.DiskType).map(row => {
    const payg = prices.find(quote => quote.RecommendationId === row.RecommendationId && quote.Scenario === "Payg");
    const ahb = prices.find(quote => quote.RecommendationId === row.RecommendationId && quote.Scenario === "Ahb");
    return {
      DiskType: row.DiskType, VmSize: row.VmSize, SizingStatus: row.Status,
      PaygMonthly: payg ? money(payg.TotalMonthly, payg.Currency) : "Unavailable",
      AhbMonthly: ahb ? money(ahb.TotalMonthly, ahb.Currency) : "Unavailable",
      SuggestedPayg: !!payg?.IsSuggested, SuggestedAhb: !!ahb?.IsSuggested,
      Suggestion: payg?.SuggestionReason || row.Reason
    };
  });
  if (diskComparison.length) {
    table(byId("pricing-content"), diskComparison, columns(["DiskType", "VmSize", "SizingStatus", "PaygMonthly", "AhbMonthly", "SuggestedPayg", "SuggestedAhb", "Suggestion"]), "VM disk alternatives: total VM, licensing and storage costs");
    byId("pricing-content").append(element("p", "Suggestions compare complete quotes within the observed latency policy, not negotiated prices or guaranteed target latency. A high queue alone does not establish a bottleneck. Ultra capacity billing is conservatively rounded because published billing references conflict.", "notice"));
  }
  prices.forEach(quote => {
    const card = element("article", null, "detail-card");
    const rec = recommendations.find(row => row.RecommendationId === quote.RecommendationId);
    card.append(element("h3", text(quote.RecommendationId) + " / " + text(quote.Scenario) +
      (rec ? " / " + text(rec.Target) + " / " + text(rec.Database || "Instance") : "")), badge(quote.Status));
    facts(card, [
      ["Total monthly (" + text(quote.Status) + ")", money(quote.TotalMonthly, quote.Currency)],
      ["Region / monthly hours", text(quote.Region) + " / " + text(quote.HoursPerMonth)]
    ]);
    if (quote.DiskType) facts(card, [["Disk type", quote.DiskType], ["Suggested for this scenario", quote.IsSuggested], ["Suggestion", quote.SuggestionReason], ["Disk billing policy", quote.DiskBillingPolicy]]);
    if (quote.Status !== "Complete") card.append(element("p", "Not a complete estimate. Inspect missing components, eligibility, and errors before using this total.", "notice"));
    table(card, array(quote.Components), columns(["Component", "MeterId", "Quantity", "Unit", "Rate", "TierMinimumUnits", "MonthlyCost", "EffectiveStartDate", "RetrievedAt"]), "Itemized " + text(quote.Scenario) + " price components");
    detail(card, "Price errors and missing meters", quote.Errors);
    detail(card, "Price freshness, allowances, exclusions, and quote evidence", Object.fromEntries(Object.entries(quote).filter(([key]) => !["Components", "Errors"].includes(key))));
    byId("pricing-content").append(card);
  });
  facts(byId("provenance-content"), [["Assessment ID", data.AssessmentId], ["Schema version", data.SchemaVersion], ["Generated at", data.GeneratedAt]]);
  [["Versions and collection identity", data.Provenance], ["Configuration", data.Configuration], ["Assumptions", data.Assumptions],
    ["Known limitations", data.Limitations], ["Diagnostics", data.Diagnostics]].forEach(([title, content]) => detail(byId("provenance-content"), title, content));
  const references = array(data.DocumentationReferences);
  references.forEach(reference => {
    const p = element("p");
    p.append(documentation(typeof reference === "string" ? reference : reference.SourceUrl));
    byId("provenance-content").append(p);
  });
  byId("provenance-content").append(element("p", "No full SQL definitions or job-step commands are included. Review the separate, sensitive collection bundle for offline reevaluation. Unknown or unavailable evidence must remain visible; the report does not certify application/runtime coverage."));
  const print = () => {
    findingControls.reset.click();
    coverageControls.reset.click();
    clientLocation.value = ""; clientSearch.value = ""; drawClients();
    document.querySelectorAll("details").forEach(node => { node.open = true; });
  };
  window.addEventListener("beforeprint", print);
  byId("print-report").addEventListener("click", () => { print(); window.print(); });
})();
