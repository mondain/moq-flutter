#ifndef MOQ_QUIC_H
#define MOQ_QUIC_H

#ifdef __cplusplus
extern "C" {
#endif

// Initialize the QUIC transport module
void moq_quic_init(void);

// Create a new QUIC connection
// Returns 0 on success, negative error code on failure
int moq_quic_connect(
    const char *host,
    uint16_t port,
    uint64_t *out_connection_id
);

// Send data over the QUIC connection
// Returns number of bytes sent on success, negative on error
int64_t moq_quic_send(
    uint64_t connection_id,
    const uint8_t *data,
    size_t len
);

// Receive data from the QUIC connection (non-blocking)
// Returns number of bytes received, 0 if no data, negative on error
int64_t moq_quic_recv(
    uint64_t connection_id,
    uint8_t *buffer,
    size_t buffer_len
);

// Check if connection is established
int moq_quic_is_connected(uint64_t connection_id);

// Close a QUIC connection
int moq_quic_close(uint64_t connection_id);

// Cleanup the QUIC transport module
void moq_quic_cleanup(void);

#ifdef __cplusplus
}
#endif

#endif // MOQ_QUIC_H
