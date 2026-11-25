module ApplicationHelper
  # Each path uses a 24 × 24 viewBox. Labels belong to the adjacent text or control.
  ICON_PATHS = {
    overview: "M3 3h7v8H3z M14 3h7v5h-7z M3 15h7v6H3z M14 12h7v9h-7z",
    audit: "M9 4H5v17h14V4h-4 M9 2h6v4H9z M8 13h2l2-4 2 7 2-3h1",
    rankings: "M3 20h18 M6 16v-5 M12 16V7 M18 16V3",
    actions: "M9 4h10v16H5v-9 M3 6l2 2 4-5 M9 12h6 M9 16h5",
    integrations: "M7 3v5 M13 3v5 M5 8h10v2a5 5 0 0 1-10 0z M10 15v2a4 4 0 0 0 8 0v-2",
    tasks: "M9 5h12 M9 12h12 M9 19h12 M2 5l1.3 1.3L6 3.5 M2 12l1.3 1.3L6 10.5 M2 19l1.3 1.3L6 17.5",
    evidence: "M3 7V5h6l2 2h10v12H3z M7 11h9 M7 15h6",
    trend_up: "m3 17 6-6 4 4 8-10 M15 5h6v6",
    trend_down: "m3 7 6 6 4-4 8 10 M15 19h6v-6",
    minus: "M5 12h14",
    flag: "M5 21V4 M5 4c4-4 9 4 14 0v10c-5 4-10-4-14 0",
    map_pin: "M20 10c0 6-8 12-8 12S4 16 4 10a8 8 0 1 1 16 0Z M15 10a3 3 0 1 1-6 0 3 3 0 0 1 6 0Z",
    sparkles: "m10 3 2.1 5.9L18 11l-5.9 2.1L10 19l-2.1-5.9L2 11l5.9-2.1z M19 3v4 M17 5h4 M19 16v4 M17 18h4",
    layers: "m3 8 9-5 9 5-9 5z M3 12l9 5 9-5 M3 16l9 5 9-5",
    monitor: "M3 4h18v13H3z M12 17v4 M8 21h8",
    smartphone: "M7 2.5h10a1.5 1.5 0 0 1 1.5 1.5v16a1.5 1.5 0 0 1-1.5 1.5H7A1.5 1.5 0 0 1 5.5 20V4A1.5 1.5 0 0 1 7 2.5Z M11 18.5h2",
    search: "M16.5 10a6.5 6.5 0 1 1-13 0 6.5 6.5 0 0 1 13 0Z M15 15l6 6",
    calendar: "M4 5h16v16H4z M8 3v4 M16 3v4 M4 10h16",
    file_text: "M5 2h9l5 5v15H5z M14 2v6h5 M8 13h8 M8 17h6",
    external_link: "M13 4h7v7 M20 4 10 14 M9 5H4v15h15v-5",
    plus: "M12 5v14 M5 12h14",
    chevron_right: "m9 5 7 7-7 7",
    chevron_down: "m6 9 6 6 6-6",
    globe: "M21 12a9 9 0 1 1-18 0 9 9 0 0 1 18 0Z M3 12h18 M12 3c5 5 5 13 0 18-5-5-5-13 0-18Z",
    info: "M21 12a9 9 0 1 1-18 0 9 9 0 0 1 18 0Z M12 11v5 M12 7.8h.01",
    arrow_left: "M20 12H4 M10 6l-6 6 6 6",
    arrow_right: "M4 12h16 M14 6l6 6-6 6",
    list: "M8 6h13 M8 12h13 M8 18h13 M3 6h.01 M3 12h.01 M3 18h.01",
    target: "M21 12a9 9 0 1 1-18 0 9 9 0 0 1 18 0Z M17 12a5 5 0 1 1-10 0 5 5 0 0 1 10 0Z M12 12h.01",
    building: "M5 21V3h12v18 M3 21h18 M17 10h3v11 M8 7h1 M12 7h1 M8 11h1 M12 11h1 M9 21v-5h4v5",
    check: "m4 12 5 5L20 6",
    settings: "M3 6h8 M15 6h6 M3 12h3 M10 12h11 M3 18h12 M19 18h2 M12 4v4 M7 10v4 M16 16v4"
  }.freeze

  def ui_icon(name, size: 18)
    content_tag(:svg, width: size, height: size, viewBox: "0 0 24 24", fill: "none",
      stroke: "currentColor", "stroke-width": 1.8, "stroke-linecap": "round", "stroke-linejoin": "round",
      class: "ui-icon", "aria-hidden": "true", focusable: "false") do
      tag.path(d: ICON_PATHS.fetch(name))
    end
  end

  def workspace_navigation
    [
      [:overview, "Overview", dashboard_path, %w[overviews]],
      [:rankings, "Rankings", rankings_path, %w[dashboard keywords rank_imports]],
      [:actions, "Actions", actions_path, %w[keyword_actions action_drafts wording_settings]],
      [:audit, "Site audit", site_audit_path, %w[site_audits]],
      [:integrations, "Integrations", integrations_path, %w[integrations search_console analytics local_falcon_connections]],
      [:calendar, "Schedules", schedules_path, %w[schedules]],
      [:sparkles, "Assistant", assistant_path, %w[assistants assistant_settings]],
      [:tasks, "Project tasks", project_tasks_path, %w[project_tasks]],
      [:evidence, "Evidence", source_snapshots_path, %w[source_snapshots project_imports]]
    ]
  end
end
