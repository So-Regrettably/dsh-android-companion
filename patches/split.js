/**
 * Outbound text shaping: Markdown stripping for
 * QQ, [[qq_forward]] block parsing, and the sensitive-intent audit.
 * Ported from the Hermes onebot_utils.py split/markdown half.
 * @module dsh-onebot/split
 */
/**
 * Strip Markdown into QQ-friendly plain text. QQ does not render Markdown;
 * headings, emphasis, links, code fences, and tables are flattened. The
 * internal [[qq_forward]] markers are preserved (handled before this runs).
 * @param text - model-produced Markdown text.
 * @returns plain text for QQ.
 */
export function stripMarkdown(text) {
    let out = text
        // Code fences: keep the inner text, drop the fence lines.
        .replace(/\x60\x60\x60[^\n]*\n([\s\S]*?)\x60\x60\x60/g, (_, body) => body + '\n')
        .replace(/\x60\x60\x60([\s\S]*?)\x60\x60\x60/g, '$1')
        // Inline code: keep content, drop backticks.
        .replace(/\x60([^\x60\n]+)\x60/g, '$1')
        // Headings.
        .replace(/^#{1,6}[ \t]+/gm, '')
        // Emphasis.
        .replace(/\*\*([^*]+)\*\*/g, '$1')
        // 2026-11-06：下划线强调只在「两侧是词边界」时才成立。
        // 原来写的是 `(^|[^_])_([^_]+)_([^_]|$)`，它会吃掉标识符中间的下划线：
        //   qq_send_image → qqsendimage
        // 她照着自己发出去的消息记工具名，就这么记错了（她自己发现的）。
        // 聊天里 `_斜体_` 几乎没人用，标识符里的下划线到处都是，所以宁可少剥一层。
        .replace(/(^|[\s，。！？；：、（）()【】「」《》<>"'‘“])(_{1,2})([^_\n]+)\2(?=[\s，。！？；：、（）()【】「」《》<>"'’”]|$)/g, '$1$3')
        .replace(/\*([^*]+)\*/g, '$1')
        .replace(/~~([^~]+)~~/g, '$1')
        // Links and images.
        .replace(/!\[([^\]]*)\]\(([^)\s]+)(?:\s+"[^"]*")?\)/g, '[图片]')
        .replace(/\[([^\]]+)\]\(([^)\s]+)(?:\s+"[^"]*")?\)/g, '$1 ($2)')
        // Blockquote markers.
        .replace(/^[ \t]*>[ \t]?/gm, '')
        // Table rows: keep cell text separated by spaces; drop divider rows.
        .split('\n')
        .map(line => {
        if (/^\s*\|?[\s:|-]+\|?\s*$/.test(line) && line.includes('|') && !line.includes('\n')) {
            const cells = line.split('|').filter(c => c.trim() !== '');
            if (cells.every(c => /^:?-{2,}:?$/.test(c.trim())))
                return '';
        }
        if (line.trim().startsWith('|')) {
            return line.split('|').map(c => c.trim()).filter(c => c !== '').join(' ');
        }
        return line;
    })
        .filter(line => line !== '')
        .join('\n')
        // Horizontal rules.
        .replace(/^\s*(?:-{3,}|\*{3,}|_{3,})\s*$/gm, '')
        // Collapse 3+ blank lines.
        .replace(/\n{3,}/g, '\n\n');
    return out.trim();
}
/** The [[qq_forward]] marker regex (imported from cq.ts for single sourcing). */
import { FORWARD_BLOCK_RE } from './cq.js';
export { FORWARD_BLOCK_RE };
/**
 * Extract [[qq_forward]] blocks from reply text. The blocks are removed from
 * the returned body text; empty-name blocks default the sender name.
 * @param text - the reply text (before Markdown stripping).
 * @param defaultName - node name when the block omits one.
 * @returns body text without blocks, plus the parsed nodes.
 */
export function extractForwardBlocks(text, defaultName) {
    const nodes = [];
    const body = text.replace(FORWARD_BLOCK_RE, (_, block) => {
        const trimmed = block.trim();
        if (trimmed === '')
            return '';
        const lines = trimmed.split('\n');
        const first = lines[0].trim();
        let name = defaultName;
        let content = trimmed;
        if (first.length <= 24 && !first.includes('：') && !first.includes(':') && lines.length > 1) {
            name = first;
            content = lines.slice(1).join('\n').trim();
        }
        if (content !== '')
            nodes.push({ name, content });
        return '';
    });
    return { body, nodes };
}
/** Sensitive-intent audit: log a WARNING when outbound text matches. */
const DEFAULT_SENSITIVE_PATTERNS = [
    /(?:rm\s+-rf|format\s+[a-z]:|diskpart|mkfs\.)/i,
    /(?:shutdown|reboot|poweroff|init\s+0)/i,
    /(?:DROP\s+TABLE|TRUNCATE\s+TABLE|DELETE\s+FROM)/i,
    /(?:sk-|ghp_|api[_-]?key|password|passwd|secret|token)\s*[:=]\s*\S+/i,
];
/**
 * Check outbound text against sensitive patterns (soft audit, non-blocking).
 * @param text - outbound text.
 * @param patterns - configured patterns; empty list disables the audit.
 * @returns matched patterns (strings), or [] when clean or disabled.
 */
export function scanSensitive(text, patterns) {
    const list = patterns.length > 0 ? patterns : DEFAULT_SENSITIVE_PATTERNS;
    const hits = [];
    for (const p of list) {
        const re = p instanceof RegExp ? p : new RegExp(p, 'i');
        if (re.test(text))
            hits.push(String(p));
    }
    return hits;
}
