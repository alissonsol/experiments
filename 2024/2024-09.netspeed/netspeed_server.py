import socket
import time
from datetime import datetime

# Configuration
SERVER_HOST = '0.0.0.0'  # Listen on all interfaces
SERVER_PORT = 80          # Default port

def handle_client_connection(client_socket, client_address):
    try:
        # print(f"Connection established with {client_address}")
        
        # Receive and send 100 packets to measure network speed
        packet_size = 1024
        total_packets = 100
        
        # Start measuring download speed
        start_time = time.time()
        for _ in range(total_packets):
            try:
                data = client_socket.recv(packet_size)
                if not data:
                    # Client disconnected, no need to raise an error.
                    return  # Exit silently if client disconnects
            except ConnectionError:
                # Silently exit if any connection error occurs
                return  
        
        download_duration = time.time() - start_time

        # Send 100 packets to measure upload speed
        start_time = time.time()
        for _ in range(total_packets):
            try:
                client_socket.sendall(b'x' * packet_size)
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
        server_socket.bind((SERVER_HOST, SERVER_PORT))
        server_socket.listen(5)
        
        # Print server IP address
        server_ip = socket.gethostbyname(socket.gethostname())
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
