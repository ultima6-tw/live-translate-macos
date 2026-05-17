import Foundation

struct HallucinationFilter {
    private var recent: [String] = []

    // Port of meeting.py: is_hallucination()
    func isHallucination(_ text: String) -> Bool {
        guard !text.isEmpty else { return false }
        let s = text

        // Non-Latin / non-CJK character ratio > 30 %
        var nonTarget = 0
        for scalar in s.unicodeScalars {
            let v = scalar.value
            let ok = (0x20...0xFF).contains(v)
                || (0x3000...0x9FFF).contains(v)
                || (0xF900...0xFAFF).contains(v)
                || (0x20000...0x2FA1F).contains(v)
            if !ok { nonTarget += 1 }
        }
        if Double(nonTarget) > Double(s.count) * 0.3 { return true }

        // Character prefix repeat
        let chars = Array(s)
        for n in 2..<min(8, chars.count) {
            let prefix = String(chars.prefix(n))
            let count = s.components(separatedBy: prefix).count - 1
            if count >= max(5, chars.count / n / 2) { return true }
        }

        // Word phrase repeat ≥ 3 times
        let words = s.split(separator: " ").map(String.init)
        if words.count >= 3 {
            for size in [1, max(1, words.count / 3)] {
                let phrase = words.prefix(size).joined(separator: " ")
                if s.components(separatedBy: phrase).count - 1 >= 3 { return true }
            }
        }

        return false
    }

    // Returns true if text is a cross-segment duplicate (seen ≥ 2 times in last 5)
    mutating func isDuplicateAndRecord(_ text: String) -> Bool {
        let count = recent.filter { $0 == text }.count
        recent.append(text)
        if recent.count > 5 { recent.removeFirst() }
        return count >= 2
    }
}
