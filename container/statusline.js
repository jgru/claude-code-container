#!/usr/bin/env node
let input = '';
process.stdin.on('data', chunk => input += chunk);
process.stdin.on('end', () => {
    const data = JSON.parse(input);
    const model = data.model.display_name;

    const now = Math.floor(Date.now() / 1000);

    // Compact time-until-reset from a Unix-epoch-seconds timestamp: "3d4h", "2h13m", "45m", "now".
    const countdown = (resetsAt) => {
        if (resetsAt == null) return null;
        let diff = resetsAt - now;
        if (diff <= 0) return 'now';
        const d = Math.floor(diff / 86400); diff %= 86400;
        const h = Math.floor(diff / 3600); diff %= 3600;
        const m = Math.floor(diff / 60);
        if (d > 0) return `${d}d${h}h`;
        if (h > 0) return `${h}h${m}m`;
        return `${m}m`;
    };

    // "24% (2h13m)" for a window, or null when the window is absent.
    const win = (w) => {
        const pct = w?.used_percentage;
        if (pct == null) return null;
        const cd = countdown(w?.resets_at);
        return cd ? `${Math.round(pct)}% (${cd})` : `${Math.round(pct)}%`;
    };

    const parts = [];
    const fiveH = win(data.rate_limits?.five_hour);
    const week = win(data.rate_limits?.seven_day);
    if (fiveH) parts.push(`5h: ${fiveH}`);
    if (week) parts.push(`7d: ${week}`);

    console.log(parts.length ? `[${model}] | ${parts.join(' | ')}` : `[${model}]`);
});
