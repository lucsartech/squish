package com.lucsartech.squish.compression;

import java.time.Duration;
import java.util.Optional;

/**
 * Result of a PDF compression operation.
 * Sealed interface for type-safe success/failure handling.
 */
public sealed interface CompressionResult {

    long id();
    long ctr();  // Counter for composite PK (OTTI_ID, OTTI_CTR)
    String filename();

    record Success(
            long id,
            long ctr,
            String filename,
            byte[] compressedData,
            long originalSize,
            long compressedSize,
            Duration processingTime
    ) implements CompressionResult {

        public double compressionRatio() {
            return originalSize > 0 ? (double) compressedSize / originalSize : 1.0;
        }

        public double savingsPercent() {
            return (1.0 - compressionRatio()) * 100.0;
        }

        public long savedBytes() {
            return originalSize - compressedSize;
        }
    }

    record Failure(
            long id,
            long ctr,
            String filename,
            String errorMessage,
            Optional<Throwable> cause
    ) implements CompressionResult {

        public static Failure of(long id, long ctr, String filename, Throwable cause) {
            return new Failure(id, ctr, filename, cause.getMessage(), Optional.of(cause));
        }

        public static Failure of(long id, long ctr, String filename, String message) {
            return new Failure(id, ctr, filename, message, Optional.empty());
        }
    }

    /**
     * Result for files that are left untouched: not a PDF, already as small as we can
     * make them, or encrypted so that iText refuses to rewrite them.
     */
    record Skipped(
            long id,
            long ctr,
            String filename,
            long size,
            String reason,
            boolean noGain
    ) implements CompressionResult {

        public static Skipped notPdf(long id, long ctr, String filename, long size) {
            return new Skipped(id, ctr, filename, size, "Not a PDF file", false);
        }

        /**
         * Compression produced a document at least as large as the input, so the
         * original must be preserved rather than overwritten. Unlike {@link #notPdf},
         * the input here is a valid PDF that is simply already optimal.
         */
        public static Skipped noGain(long id, long ctr, String filename, long size, long compressedSize) {
            return new Skipped(id, ctr, filename, size,
                    "No size gain (%d -> %d bytes)".formatted(size, compressedSize), true);
        }

        /**
         * The PDF is encrypted/protected and iText cannot rewrite it (no owner password, an
         * unsupported encryption scheme, or a decryption that fails), so the original is
         * left untouched - a deliberate skip, not a failure. Common for fiscal documents
         * whose issuer locked modification. {@code noGain} is false: this is not a valid PDF
         * we simply could not improve, it is one we chose not to touch. The detail (the iText
         * message, or the probed crypto failure) is kept as the reason so the cases stay
         * distinguishable in the tracking table - e.g. owner vs user password.
         */
        public static Skipped encrypted(long id, long ctr, String filename, long size, String detail) {
            return new Skipped(id, ctr, filename, size, "Encrypted: " + detail, false);
        }
    }

    default boolean isSuccess() {
        return this instanceof Success;
    }

    default boolean isSkipped() {
        return this instanceof Skipped;
    }

    default boolean isFailure() {
        return this instanceof Failure;
    }

    default Optional<Success> asSuccess() {
        return this instanceof Success s ? Optional.of(s) : Optional.empty();
    }

    default Optional<Failure> asFailure() {
        return this instanceof Failure f ? Optional.of(f) : Optional.empty();
    }
}
