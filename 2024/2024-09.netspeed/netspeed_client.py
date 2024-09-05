import socket
import time
import sys
from datetime import datetime

# Configuration
DEFAULT_PORT = 80
PACKET_SIZE = 1024
TOTAL_PACKETS = 100

def get_local_ip():
    try:
        # Use a dummy connection to an external address to get the local IP address
        with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as s:
            # We connect to an external IP address without sending data (no actual connection is made)
            s.connect(('8.8.8.8', 80))
            local_ip = s.getsockname()[0]
        return local_ip
    except Exception as e:
        # If any error occurs, fall back to localhost
        print(f"Error obtaining local IP: {e}")
        return '127.0.0.1'

def ping_latency(server_address, port):
    try:
        start_time = time.time()
        with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as sock:
            sock.connect((server_address, port))
        return (time.time() - start_time) * 1000  # Convert to milliseconds
    except (socket.error, ConnectionError) as e:
        print(f"Error during ping latency measurement: {e}")
        sys.exit(1)

def measure_speed(server_address, port):
    try:
        client_socket = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        client_socket.connect((server_address, port))
        
        # Measure upload speed
        start_time = time.time()
        for _ in range(TOTAL_PACKETS):
            client_socket.sendall(b'x' * PACKET_SIZE)
        upload_duration = time.time() - start_time
        
        # Measure download speed
        start_time = time.time()
        for _ in range(TOTAL_PACKETS):
            data = client_socket.recv(PACKET_SIZE)
            if not data:
                raise ConnectionError("Server closed the connection during download speed measurement.")
        download_duration = time.time() - start_time
        
        return client_socket, upload_duration, download_duration
    
    except (socket.error, ConnectionError) as e:
        print(f"Error during speed measurement: {e}")
        sys.exit(1)

def main():
    if len(sys.argv) < 2:
        print("Usage: netspeed_client.py <server_address> [port]")
        sys.exit(1)
    
    server_address = sys.argv[1]
    port = int(sys.argv[2]) if len(sys.argv) > 2 else DEFAULT_PORT
    
    try:
        # Get client and server IP addresses
        client_ip = get_local_ip()
        server_ip = socket.gethostbyname(server_address)
        print(f"Connecting to server {server_ip}:{port} from client {client_ip}...")
        
        # Measure ping latency
        latency = ping_latency(server_address, port)
        print(f"Ping latency: {latency:.2f} ms")
        
        # Measure upload and download speeds
        client_socket, upload_duration, download_duration = measure_speed(server_address, port)
        
        # Calculate speeds in Mbps
        upload_speed = (TOTAL_PACKETS * PACKET_SIZE * 8) / (upload_duration * 1e6)  # Mbps
        download_speed = (TOTAL_PACKETS * PACKET_SIZE * 8) / (download_duration * 1e6)  # Mbps
        
        # Get the current date and time
        current_time = datetime.now().strftime('%Y-%m-%d %H:%M:%S')
        
        # Prepare the result string
        # result = (f"{current_time}, Client IP: {client_ip}, Server IP: {server_ip}, "
        #           f"Ping: {latency:.2f} ms, Upload: {upload_speed:.2f} Mbps, "
        #           f"Download: {download_speed:.2f} Mbps")
        result = (f"{current_time}, {client_ip}, {server_ip}, "
                  f"{latency:.2f}, {upload_speed:.2f}, "
                  f"{download_speed:.2f}")
        
        # Print the results on client side
        print(result)
        
        # Send the results to the server
        client_socket.sendall(result.encode())
    
    except Exception as e:
        print(f"Unexpected error: {e}")
    finally:
        if 'client_socket' in locals():
            client_socket.close()

if __name__ == "__main__":
    main()
