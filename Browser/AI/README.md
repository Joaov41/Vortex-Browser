# AI Panel Integration

- Toggle the AI panel with the toolbar button (sparkles icon).
- Ask questions about the current page; the app extracts visible text via JavaScript and sends it as context.
- `SimpleAIService` supports:
  - Apple local (FoundationModels / Apple Intelligence).
  - Apple Cloud (direct Private Cloud Compute on iOS 27, or Shortcuts on iOS 26).
  - MLX local (mlx-swift + mlx-swift-lm).
  - Web sessions for ChatGPT and Gemini.

MLX requires the MLX Swift packages and Apple Silicon; configure the model id and token limits in the AI panel.

For user setup and the iOS 26/iOS 27 distinction, see
[Using AI models in Vortex](../../docs/AI_MODELS.md).
