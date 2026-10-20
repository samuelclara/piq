import Foundation

extension String {
    /// The copy as VoiceOver should say it: the "·" that separates the parts of a line on screen
    /// becomes a pause, so "Start sorting · 400 photos" reads "Start sorting, 400 photos".
    var spoken: String {
        replacingOccurrences(of: " · ", with: ", ")
    }
}
