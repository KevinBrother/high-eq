package service

import (
	"os"

	"high-eq/server/internal/payments"
)

func paymentChannels() (payments.Channels, error) { return payments.Configure(os.Getenv) }
