//go:build ignore

package protocol

import (
	"errors"
	"net"
	"sync"

	"github.com/google/uuid"
)

type TCPListener struct {
	ListenAddr   string
	Listener     net.Listener
	RequestsChan chan<- []byte
}

func NewTCPListener(listenaddress ListenAddr) TCPListener {
	NewTCPListener := TCPListener{
		ListenAddr: listenaddress,
	}

	return NewTCPListener
}

func handleConnection(conn net.Conn) error {

	GetServer()
	// send to this
	return errors.New("trouble handling connection")
}

func (t *TCPListener) Listen(MaxConcReq int, LocalMaxConcListener *sync.WaitGroup) error {
	sem := make(chan string, MaxConcReq)
	var err error
	t.Listener, err = net.Listen("tcp", t.ListenAddr)
	if err != nil {
		return err
	}

	for {
		conn, err := t.Listener.Accept()
		if err != nil {
			return err
		}
		sem <- uuid.NewString()
		go func(connection net.Conn) error {
			defer func() {
				<-sem
				connection.Close()
			}()

			return handleConnection(connection)
		}(conn)
	}

}
