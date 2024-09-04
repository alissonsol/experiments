import socket
import time
from datetime import datetime

# Configuration
SERVER_HOST = '0.0.0.0'  # Listen on all interfaces
SERVER_PORT = 80          # Default port

def handle_client_connection(client_socket, client_address):
    try:
        print(f"Connection established with {client_address}")
        
        # Receive and send 100 packets to measure network speed
        packet_size = 1024
        total_packets = 100
        
        # Start measuring download speed
        start_time = time.time()
        for _ in range(total_packets):
            try:
                data = client_socket.recv(packet_size)
                if not data:
                    break  # Suppress specific error message and break out
            except ConnectionError:
                break  # Suppress specific error message and break out
        download_duration = time.time() - start_time

        # Send 100 packets to measure upload speed
        start_time = time.time()
        for _ in range(total_packets):
            client_socket.sendall(b'x' * packet_size)
        upload_duration = time.time() - start_time
        
        # Receive final results from the client
        final_result = client_socket.recv(1024).decode()
        print(f"Results received from client: {final_result}")
        
    except (socket.error, ConnectionError) as e:
        if "Client closed the connection during download speed measurement" not in str(e):
            print(f"Error during communication with {client_address}: {e}")
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
        
        while True:
            try:
                client_socket, client_address = server_socket.accept()
                handle_client_connection(client_socket, client_address)
            except KeyboardInterrupt:
                print("\nServer is shutting down...")
                break
            
    except socket.error as e:
        print(f"Socket error: {e}")
    except Exception as e:
        print(f"Unexpected error: {e}")
    finally:
        server_socket.close()
        print("Server closed successfully.")

if __name__ == "__main__":
    main()
