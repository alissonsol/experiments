import socket
import time
from datetime import datetime

# Configuration
SERVER_HOST = '0.0.0.0'  # Listen on all interfaces
SERVER_PORT = 80          # Default port
PACKET_SIZE = 1024
TOTAL_PACKETS = 1024

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

def handle_client_connection(client_socket, client_address):
    try:
        # print(f"Connection established with {client_address}")
        
        # Start measuring download speed
        start_time = time.time()
        for _ in range(TOTAL_PACKETS):
            try:
                data = client_socket.recv(PACKET_SIZE)
                if not data:
                    # Client disconnected, no need to raise an error.
                    return  # Exit silently if client disconnects
            except ConnectionError:
                # Silently exit if any connection error occurs
                return  
        
        download_duration = time.time() - start_time

        # Send packets to measure upload speed
        start_time = time.time()
        for _ in range(TOTAL_PACKETS):
            try:
                client_socket.sendall(b'x' * PACKET_SIZE)
            except BrokenPipeError:
                # Silently exit if client disconnects during upload
                return  
        upload_duration = time.time() - start_time
        
        # Receive final results from the client
        try:
            final_result = client_socket.recv(1024).decode()
            if final_result:
                print(f"{final_result}")
        except ConnectionError:
            # Silently handle connection error during final result reception
            pass
        
    finally:
        client_socket.close()

def main():
    try:
        server_socket = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        server_socket.bind((SERVER_HOST, SERVER_PORT))  # Bind to all interfaces
        server_socket.listen(5)
        
        # Print server IP address
        server_ip = get_local_ip()
        print(f"Server listening on {server_ip}:{SERVER_PORT}")
        print(f"Date and Time, Client IP, Server IP, Ping (ms), Upload (Mbps), Download (Mbps)")
              
        while True:
            try:
                client_socket, client_address = server_socket.accept()
                handle_client_connection(client_socket, client_address)
            except KeyboardInterrupt:
                print("\nServer is shutting down...")
                break
            
    except socket.error as e:
        print(f"Socket error: {e}")
    finally:
        server_socket.close()
        print("Server closed successfully.")

if __name__ == "__main__":
    main()
