// Krea2PromptTemplate.swift
//










import Foundation

public enum Krea2PromptTemplate {

    public static let prefix = "<|im_start|>system\nDescribe the image by detailing the color, shape, size, texture, quantity, text, spatial relationships of the objects and background:<|im_end|>\n<|im_start|>user\n"


    public static let suffix = "<|im_end|>\n<|im_start|>assistant\n"


    public static let prefixTokenCount = 34


    public static let suffixTokenCount = 5


    public static let maxConditioningTokens = 512



    public static let selectLayers = [2, 5, 8, 11, 14, 17, 20, 23, 26, 29, 32, 35]

    /// pad_token <|endoftext|> (Qwen2Tokenizer).
    public static let padTokenId: Int32 = 151_643


    public static func templatedText(prompt: String) -> String {
        prefix + prompt
    }



    public static let enhanceSystemPrompt = """
        You are an expert prompt engineer for text-to-image models. Your task is to expand the user's prompt into a highly effective image-generation prompt.

        Think step by step about the request before writing the answer:
        - What is the subject and mood?
        - What visual styles, mediums, and lighting options would fit? Consider two or three alternatives and pick the one that best serves the caption.
        - What composition, framing, and grounded details will help the text-to-image model?

        Then output a single expanded prompt paragraph.

        Follow these rules strictly:
        1. **Faithfulness First:** Preserve all original subjects, actions, colors, and spatial relationships. Do not add new objects, props, characters, or animals unless the user clearly implies them.
        2. **Practical T2I Structure:** Write a prompt that a text-to-image model can parse cleanly. Group subjects with their own attributes and actions. Use grounded phrasing for poses, interactions, and spatial layout.
        3. **Style Planning Stays Internal:** Use your internal reasoning to choose style, medium, framing, and lighting. Do not emit planning tags or wrappers in the visible answer body.
        4. **Text Rendering:** If the user requests visible text, quotes, labels, or typography, specify the exact text clearly and wrap requested words in quotes.
        5. **Avoid Over-Specification:** Do not invent highly specific clothing, colors, materials, or scene details unless the input supports them.
        6. **Structure:** Write one cohesive paragraph after the thinking block. No bullets, JSON, or markdown.
        7. **Respect Existing Detail:** If the user's prompt is already detailed, lightly polish and finalize rather than heavily expanding — preserve their phrasing and direction.
        8. **Respect the Human Form:** Treat depictions of people with dignity. Assume clothing covers genitals and intimate anatomy.
        9. **Preserve User Medium:** When the user explicitly requests a medium (e.g. "photo of", "photograph of", "illustration of", "painting of", "sketch of", "3D render of"), honor it. Do not pivot to a different medium to avoid difficulty — match the user's stated intent.
        """




    public static func enhanceChatText(prompt: String) -> String {
        "<|im_start|>system\n\(enhanceSystemPrompt)<|im_end|>\n<|im_start|>user\n\(prompt)<|im_end|>\n<|im_start|>assistant\n"
    }


    /// - Parameters:




    public static func pack(
        prefixAndPromptIds: [Int32],
        suffixIds: [Int32],
        maxLength: Int = maxConditioningTokens,
        padTokenId: Int32 = padTokenId
    ) -> (inputIds: [Int32], mask: [Int32]) {

        let paddedLength = maxLength + prefixTokenCount - suffixTokenCount

        var body = prefixAndPromptIds
        if body.count > paddedLength {
            body = Array(body.prefix(paddedLength)) // truncation=True
        }
        let validBodyCount = body.count
        if body.count < paddedLength {
            body.append(contentsOf: Array(repeating: padTokenId, count: paddedLength - body.count))
        }

        let inputIds = body + suffixIds
        var mask = [Int32](repeating: 0, count: inputIds.count)
        for i in 0 ..< validBodyCount { mask[i] = 1 }
        for i in paddedLength ..< inputIds.count { mask[i] = 1 }
        return (inputIds, mask)
    }
}
