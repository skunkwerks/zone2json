import pika
import uuid
import pathlib
import sys

class Zone2JsonRpcClient:

    def __init__(self):
        self.connection = pika.BlockingConnection(pika.ConnectionParameters(host='localhost'))

        self.channel = self.connection.channel()

        result = self.channel.queue_declare(queue='', exclusive=True)
        self.callback_queue = result.method.queue

        self.channel.basic_consume(
            queue=self.callback_queue,
            on_message_callback=self.on_response,
            auto_ack=True
        )

    def on_response(self, ch, method, props, body):
        if self.corr_id == props.correlation_id:
            self.response = body

    def call(self, dns):
        self.response = None
        self.corr_id = str(uuid.uuid4())
        self.channel.basic_publish(
            exchange='',
            routing_key='zone2json',
            properties=pika.BasicProperties(
                reply_to=self.callback_queue,
                correlation_id=self.corr_id,
                content_type='text/dns',
            ),
            body=dns
        )
        while self.response is None:
            self.connection.process_data_events()
        return self.response.decode()

zone2json_rpc = Zone2JsonRpcClient()

print(zone2json_rpc.call(pathlib.Path(sys.argv[1]).read_text()))
